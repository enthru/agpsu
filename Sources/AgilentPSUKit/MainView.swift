import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PSUCore

/// The main window.
///
/// Laid out for the screen a bench Mac actually has rather than for a narrow
/// column: the readout across the top, the instrument facts in a strip under
/// it, the controls in a grid that takes two columns when there is width for
/// them, and the right-hand side given over to the live trace with the event
/// list underneath. The controls used to be five boxes stacked in one column,
/// which meant scrolling past three of them to reach the fourth while half a
/// wide window sat empty — and the graphs lived only in windows of their own,
/// so nothing moved on screen unless you opened one.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var trace: GraphKind = .voltage

    private var controller: PSUController { model.controller }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ReadoutPanel()
            InstrumentStrip()
            Divider()

            HSplitView {
                ScrollableColumn { ControlGrid() }
                    .frame(minWidth: 330, idealWidth: 640)

                liveData
                    .frame(minWidth: 300, idealWidth: 540)
            }

            StatusBar()
        }
        .frame(minWidth: 900, minHeight: 660)
        .sheet(isPresented: $model.isConnectionSheetPresented) {
            ConnectionView()
        }
        .navigationTitle(controller.deviceTitle)
        .navigationSubtitle(controller.isConnected ? controller.portDisplayName : "not connected")
        .focusedSceneValue(\.exportAction, ExportAction(title: "Export Event List…", perform: exportEntries))
        .onDisappear { controller.disconnect() }
    }

    // MARK: - Live data

    /// The trace over the record of what happened. A split rather than tabs:
    /// watching the curve and reading the log is the same activity.
    ///
    /// Both halves are told to fill the width. A `VSplitView` takes its width
    /// from its children, and children that merely hug their content leave the
    /// split sized to the widest label in it.
    private var liveData: some View {
        VSplitView {
            tracePane
                .frame(maxWidth: .infinity, minHeight: 160, idealHeight: 320)
            eventPane
                .frame(maxWidth: .infinity, minHeight: 110, idealHeight: 200)
        }
    }

    private var history: SampleBuffer { model.history(for: trace) }

    private var tracePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $trace) {
                    ForEach(GraphKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                Text("\(history.samples.count) samples")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Open Window") { openWindow(id: trace.windowID) }
                    .controlSize(.small)
                    .help("The same trace in a window of its own, with export and per-graph settings")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            if history.isEmpty {
                // A blank white rectangle explains nothing. Say what is missing
                // and how to get some.
                ContentUnavailableView {
                    Label("No samples yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text(controller.isConnected
                         ? "The trace appears as the polling loop reports readings."
                         : "Connect a supply, or Config ▸ Start Built-in Simulator to try it without one.")
                } actions: {
                    if !controller.isConnected {
                        Button("Select Serial Port…") { model.isConnectionSheetPresented = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SeriesChart(samples: history.decimated(into: 600),
                            bounds: history.bounds,
                            unit: trace.unit,
                            seriesName: trace.title,
                            settings: model.settings(for: trace),
                            markers: GraphMarkers.forVoltage(kind: trace,
                                                             settings: model.settings(for: trace),
                                                             controller: controller),
                            isCompact: true)
                    .padding(8)
                    .background(model.settings(for: trace).figureBackground.color)
            }
        }
    }

    private var eventPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Events")
                    .font(.system(size: 11, weight: .medium))
                Text("\(controller.entries.count) entries")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { controller.clearEntries() }
                    .controlSize(.small)
                    .disabled(controller.entries.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            if controller.entries.isEmpty {
                Text("Nothing has happened yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EventListView()
            }
        }
    }

    // MARK: - Export

    /// ⌘S in the main window: the event list, exactly as shown, as a text file.
    private func exportEntries() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Event-List.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = controller.entries.map(\.text).joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: url)
    }
}

/// A scrolling column whose scroller is visible whenever there is something to
/// scroll — and absent when there is not.
///
/// macOS overlay scrollers fade out a second after the scroll stops, so a pane
/// with more content below looks exactly like a pane with nothing below;
/// `.scrollIndicators(.visible)` asks for a visible indicator and still gets one
/// that disappears. The legacy scroller reserves its own strip and does not
/// fade. Its `autohidesScrollers` is left on, which for that style means "hide
/// when the content fits" rather than "hide after scrolling" — so an area that
/// cannot scroll does not grow a scroll bar to say so.
struct ScrollableColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .background(PersistentScroller().frame(width: 0, height: 0))
        }
    }
}

/// Switches the enclosing `NSScrollView` to a scroller that does not fade.
///
/// A zero-sized probe rather than a wrapper: it only needs to reach the scroll
/// view SwiftUI already made, and wrapping the whole column in an
/// `NSViewRepresentable` would mean giving up SwiftUI's layout inside it.
private struct PersistentScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureEnclosingScrollView()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureEnclosingScrollView()
        }

        private func configureEnclosingScrollView() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .legacy
            scrollView.hasVerticalScroller = true
            // Left on deliberately: for a legacy scroller this means "only when
            // the content does not fit", which is the whole point.
            scrollView.autohidesScrollers = true

            // A legacy scroller at its regular size takes a fifteen-point strip
            // out of a column that is already narrow. The small control size is
            // about two thirds of that and still plainly a scroll bar.
            scrollView.verticalScroller?.controlSize = .small
            scrollView.tile()
        }
    }
}

/// The scrolling record of everything that happened, exactly as the Windows
/// list box behaved: entries are "text,time" and can be paused or cleared.
struct EventListView: View {
    @Environment(AppModel.self) private var model

    private var controller: PSUController { model.controller }

    var body: some View {
        ScrollViewReader { proxy in
            List(controller.entries) { entry in
                Text(entry.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: controller.entries.count) {
                guard controller.autoScroll, let last = controller.entries.last else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    private var controller: PSUController { model.controller }

    var body: some View {
        HStack(spacing: 14) {
            Text("Runtime \(Format.duration(controller.runtime))")

            Divider().frame(height: 14)

            HStack(spacing: 6) {
                Text(controller.isOutputEnabled ? "Output Enabled" : "Output Disabled")
                RoundedRectangle(cornerRadius: 2)
                    .fill(controller.isOutputEnabled ? Color.green : Color.red)
                    .frame(width: 14, height: 12)
            }

            Divider().frame(height: 14)

            Text("Sampled: \(String(controller.voltageSampleCount))V  \(String(controller.currentSampleCount))C")

            if controller.logOutputText || controller.logOutputCSV || controller.logStatusText {
                Divider().frame(height: 14)
                Label("Logging", systemImage: "record.circle")
                    .foregroundStyle(.red)
            }

            if controller.protectionIsKnown && !controller.protection.isClear {
                Divider().frame(height: 14)
                Label(controller.protection.trippedLabels.joined(separator: ", "),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Spacer()

            Text("Update Speed")
            ProgressView(value: min(controller.progress, controller.progressMaximum), total: controller.progressMaximum)
                .frame(width: 110)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
