import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import PSUCore

/// One live graph window (voltage, current or power).
///
/// The Windows version used ScottPlot; this is Swift Charts. Histories can run
/// to millions of samples, so the series is decimated for drawing while the full
/// history stays available for export.
struct GraphWindow: View {
    let kind: GraphKind
    @Environment(AppModel.self) private var model

    private var controller: PSUController { model.controller }
    private var settings: GraphSettings { model.settings(for: kind) }
    private var history: SampleBuffer { model.history(for: kind) }

    var body: some View {
        VStack(spacing: 0) {
            chart
                .padding(12)
                .background(settings.figureBackground.color)

            Divider()
            informationPanel
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle("\(controller.identity?.model ?? "PSU") \(controller.portDisplayName) \(kind.title) Graph")
        .toolbar {
            ToolbarItemGroup {
                Menu("Curve Colour") {
                    ForEach(PanelColor.allCases) { color in
                        Button(color.title) { settings.curveColor = color }
                    }
                }
                Menu("Theme") {
                    ForEach(GraphTheme.allCases) { theme in
                        Button(theme.title) { settings.apply(theme: theme) }
                    }
                }
                Button("Save Image", action: saveImage)
                Button("Save Data", action: saveData)
            }
        }
        .focusedSceneValue(\.exportAction,
                           ExportAction(title: "Save \(kind.title) Graph Data…", perform: saveData))
    }

    private var samples: [PSUSample] { history.decimated() }

    @ViewBuilder
    private var chart: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value(settings.xAxis.title, xValue(for: sample)),
                    y: .value(kind.title, sample.value)
                )
                .foregroundStyle(settings.curveColor.color)
                .interpolationMethod(.linear)

                if settings.showPoints {
                    PointMark(
                        x: .value(settings.xAxis.title, xValue(for: sample)),
                        y: .value(kind.title, sample.value)
                    )
                    .foregroundStyle(settings.curveColor.color)
                    .symbolSize(12)
                }
            }

            ForEach(markers, id: \.label) { marker in
                RuleMark(y: .value(marker.label, marker.value))
                    .foregroundStyle(marker.color)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            // The labels in a second pass, carried by rules that draw nothing.
            //
            // Swift Charts paints marks in the order they are declared,
            // annotations included, so a label written beside the first rule is
            // struck through by the second rule's dashes — and on a
            // well-adjusted supply OVP sits a hundred millivolts above the set
            // point, close enough for exactly that. Every label after every
            // line, and each gets the plot's own background behind it, opaque:
            // the set point is the marker most worth reading and it is precisely
            // where the curve spends its time.
            //
            // Alternating sides keeps two close markers off each other, and
            // `fitToPlot` keeps the topmost one from being cut against the edge.
            ForEach(Array(markers.enumerated()), id: \.element.label) { index, marker in
                RuleMark(y: .value(marker.label, marker.value))
                    .foregroundStyle(.clear)
                    .annotation(position: .top,
                                alignment: index.isMultiple(of: 2) ? .leading : .trailing,
                                spacing: 2,
                                overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        Text(marker.label)
                            .font(.caption2)
                            .foregroundStyle(marker.color)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(settings.plotBackground.color)
                            )
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            // Swift Charts puts the value axis on the trailing edge by default;
            // instrument graphs read better with it on the left, as ScottPlot drew it.
            AxisMarks(position: .leading)
        }
        .chartPlotStyle { plot in
            plot.background(settings.plotBackground.color)
        }
        .chartXAxisLabel(settings.xAxis.title)
        .chartYAxisLabel(position: .leading) { Text("\(kind.title) ( \(kind.unit) )") }
    }

    private func xValue(for sample: PSUSample) -> Double {
        switch settings.xAxis {
        case .sampleNumber: return Double(sample.index)
        case .time: return sample.timestamp.timeIntervalSince(history.samples.first?.timestamp ?? sample.timestamp)
        }
    }

    private var yDomain: ClosedRange<Double> {
        guard settings.autoAxis else {
            let lower = min(settings.manualMinimum, settings.manualMaximum)
            let upper = max(settings.manualMinimum, settings.manualMaximum)
            return lower...(upper > lower ? upper : lower + 1)
        }
        var lowest = history.minimum ?? 0
        var highest = history.maximum ?? 1
        for marker in markers {
            lowest = min(lowest, marker.value)
            highest = max(highest, marker.value)
        }
        if highest - lowest < 0.001 {
            lowest -= 0.5
            highest += 0.5
        }
        let margin = (highest - lowest) * 0.08
        return (lowest - margin)...(highest + margin)
    }

    private struct Marker {
        let label: String
        let value: Double
        let color: Color
    }

    /// Set point, OVP and UVP reference lines — only meaningful on the voltage graph.
    private var markers: [Marker] {
        guard kind == .voltage else { return [] }
        var result: [Marker] = []
        if settings.showSetMarker, let value = controller.setVoltageReadback {
            result.append(Marker(label: "Set \(Format.number(value, 3))V", value: value, color: .green))
        }
        if settings.showOVPMarker, let value = controller.ovpLevel {
            result.append(Marker(label: "OVP \(Format.number(value, 2))V", value: value, color: .red))
        }
        if settings.showUVPMarker, let value = controller.uvpLevel {
            result.append(Marker(label: "UVP \(Format.number(value, 3))V", value: value, color: .orange))
        }
        return result
    }

    private var informationPanel: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 2) {
            GridRow {
                Text("Total Samples: \(String(history.samples.count))")
                Text("Recent: \(formatted(history.latest?.value))")
                Text("Max Recorded: \(formatted(history.maximum))")
            }
            GridRow {
                Text("Negative Samples: \(String(history.negativeCount))")
                Text("Recorded Overall: \(String(history.totalRecorded))")
                Text("Min Recorded: \(formatted(history.minimum))")
            }
            GridRow {
                Text("Max Allowed: \(String(history.capacity))")
                Text("Status: \(controller.outputMode.label)")
                Text(history.latest.map { DateFormatter.logTimestamp.string(from: $0.timestamp) } ?? "—")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        return Format.number(value, 5) + kind.unit
    }

    // MARK: - Export

    private func saveImage() {
        let renderer = ImageRenderer(content:
            chart
                .frame(width: 1200, height: 700)
                .padding(16)
                .background(settings.figureBackground.color)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }

        save(data: png, suggestedName: "\(kind.title)-Graph.png", type: .png)
    }

    private func saveData() {
        let csv = history.csv(valueHeader: "\(kind.title) (\(kind.unit))")
        save(data: Data(csv.utf8), suggestedName: "\(kind.title)-Graph.csv", type: .commaSeparatedText)
    }

    private func save(data: Data, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
