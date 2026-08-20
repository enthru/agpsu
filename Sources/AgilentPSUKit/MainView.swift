import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PSUCore

struct MainView: View {
    @Environment(AppModel.self) private var model

    private var controller: PSUController { model.controller }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ReadoutPanel()

            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            SetPointBox(quantity: .voltage)
                            SetPointBox(quantity: .current)
                        }
                        OutputBox()
                        ProtectionBox()
                        DisplayBox()
                        InfoBox()
                    }
                    .padding(10)
                }
                .frame(minWidth: 430, idealWidth: 470)

                EventListView()
                    .frame(minWidth: 220, idealWidth: 260)
            }

            StatusBar()
        }
        .frame(minWidth: 720, minHeight: 640)
        .sheet(isPresented: $model.isConnectionSheetPresented) {
            ConnectionView()
        }
        .navigationTitle(controller.deviceTitle)
        .focusedSceneValue(\.exportAction, ExportAction(title: "Export Event List…", perform: exportEntries))
        .onDisappear { controller.disconnect() }
    }

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
