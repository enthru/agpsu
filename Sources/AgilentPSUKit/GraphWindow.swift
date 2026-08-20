import SwiftUI
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

    private var chart: some View {
        SeriesChart(samples: samples,
                    bounds: history.bounds,
                    unit: kind.unit,
                    seriesName: kind.title,
                    settings: settings,
                    markers: markers)
    }

    /// Set point, OVP and UVP reference lines — only meaningful on the voltage
    /// graph, and the same set the trace in the main window draws.
    private var markers: [ChartMarker] {
        GraphMarkers.forVoltage(kind: kind, settings: settings, controller: controller)
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
