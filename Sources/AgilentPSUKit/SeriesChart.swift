import SwiftUI
import Charts
import PSUCore

/// Axis labels, in the same notation as every reading in the application.
///
/// Swift Charts formats numbers in the viewer's locale, which on a machine set
/// to a comma-decimal locale puts "4,19" on the axis directly above a readout
/// saying "4.190V". Instrument work is period-decimal throughout, so the labels
/// are formatted rather than left to the default.
enum AxisNumber {
    /// Decimals enough to tell one gridline from the next, and no more.
    static func decimals(forSpan span: Double, divisions: Int = 6) -> Int {
        guard span > 0, span.isFinite else { return 0 }
        let step = span / Double(divisions)
        return min(9, max(0, Int(ceil(-log10(step))) + 1))
    }

    static func label(_ value: Double, decimals: Int) -> String {
        Format.number(value, decimals)
    }
}

/// A horizontal reference line on a chart: the set point, OVP, UVP.
struct ChartMarker: Identifiable {
    let label: String
    let value: Double
    let color: Color

    var id: String { label }
}

/// The strip chart, shared by the three graph windows and the trace in the main
/// window. Same colours, same theme, same markers — the pane in the window is
/// the graph window in miniature, not a second drawing of the same data that
/// happens to look different.
struct SeriesChart: View {
    /// Already decimated: the caller owns the buffer and knows how many points
    /// its pane can use.
    let samples: [PSUSample]
    /// The extremes of the whole retained history rather than of the drawn
    /// subset. The buffer keeps them as it goes; recomputing them here would
    /// mean a pass over two million samples on every redraw.
    let bounds: ClosedRange<Double>?
    let unit: String
    let seriesName: String
    let settings: GraphSettings
    var markers: [ChartMarker] = []
    /// The main window's pane is a few hundred points tall and shares its width
    /// with the event list; axis titles there cost more room than they earn.
    var isCompact = false

    private func x(_ sample: PSUSample) -> Double {
        switch settings.xAxis {
        case .sampleNumber:
            return Double(sample.index)
        case .time:
            return sample.timestamp.timeIntervalSince(samples.first?.timestamp ?? sample.timestamp)
        }
    }

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value(settings.xAxis.title, x(sample)),
                    y: .value(seriesName, sample.value)
                )
                .foregroundStyle(settings.curveColor.color)
                .interpolationMethod(.linear)

                if settings.showPoints {
                    PointMark(
                        x: .value(settings.xAxis.title, x(sample)),
                        y: .value(seriesName, sample.value)
                    )
                    .foregroundStyle(settings.curveColor.color)
                    .symbolSize(12)
                }
            }

            ForEach(markers) { marker in
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
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
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
            // instrument graphs read better with it on the left, as ScottPlot
            // drew it.
            AxisMarks(position: .leading, values: .automatic(desiredCount: isCompact ? 4 : 6)) { mark in
                AxisGridLine().foregroundStyle(plotInk.opacity(0.22))
                AxisTick().foregroundStyle(plotInk.opacity(0.5))
                AxisValueLabel {
                    if let value = mark.as(Double.self) {
                        Text(AxisNumber.label(value, decimals: yDecimals))
                            .foregroundStyle(figureInk)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: isCompact ? 4 : 6)) { mark in
                AxisGridLine().foregroundStyle(plotInk.opacity(0.22))
                AxisTick().foregroundStyle(plotInk.opacity(0.5))
                AxisValueLabel {
                    if let value = mark.as(Double.self) {
                        Text(AxisNumber.label(value, decimals: xDecimals))
                            .foregroundStyle(figureInk)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(settings.plotBackground.color)
        }
        // The compact pane has a header saying which series it is and in what
        // unit, so the axis titles would only repeat it into a space that is
        // already short.
        .chartXAxisLabel(alignment: .center) {
            Text(isCompact ? "" : settings.xAxis.title).foregroundStyle(figureInk)
        }
        .chartYAxisLabel(position: .leading) {
            Text(isCompact ? "" : "\(seriesName) ( \(unit) )").foregroundStyle(figureInk)
        }
    }

    /// Gridlines and ticks lie on the plot; the numbers beside them lie on the
    /// figure around it. The two are separately chosen colours and can differ —
    /// a black theme with a white plot is one of the presets.
    private var plotInk: Color { settings.plotBackground.contrastingInk }
    private var figureInk: Color { settings.figureBackground.contrastingInk }

    private var yDecimals: Int {
        let domain = yDomain
        return AxisNumber.decimals(forSpan: domain.upperBound - domain.lowerBound)
    }

    /// Sample numbers are whole; a time axis wants a little precision.
    private var xDecimals: Int {
        guard settings.xAxis == .time else { return 0 }
        guard let first = samples.first, let last = samples.last else { return 0 }
        return AxisNumber.decimals(forSpan: x(last) - x(first))
    }

    private var yDomain: ClosedRange<Double> {
        guard settings.autoAxis else {
            let lower = min(settings.manualMinimum, settings.manualMaximum)
            let upper = max(settings.manualMinimum, settings.manualMaximum)
            return lower...(upper > lower ? upper : lower + 1)
        }

        var lowest = bounds?.lowerBound ?? 0
        var highest = bounds?.upperBound ?? 1
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
}

/// Which reference lines belong on a graph.
///
/// One place rather than two: the graph window and the trace in the main window
/// draw the same supply, and a set point that showed in one and not the other
/// would be a puzzle rather than a difference.
@MainActor
enum GraphMarkers {
    static func forVoltage(kind: GraphKind,
                           settings: GraphSettings,
                           controller: PSUController) -> [ChartMarker] {
        guard kind == .voltage else { return [] }
        var result: [ChartMarker] = []
        if settings.showSetMarker, let value = controller.setVoltageReadback {
            result.append(ChartMarker(label: "Set \(Format.number(value, 3))V", value: value, color: .green))
        }
        if settings.showOVPMarker, let value = controller.ovpLevel {
            result.append(ChartMarker(label: "OVP \(Format.number(value, 2))V", value: value, color: .red))
        }
        if settings.showUVPMarker, let value = controller.uvpLevel {
            result.append(ChartMarker(label: "UVP \(Format.number(value, 3))V", value: value, color: .orange))
        }
        return result
    }
}
