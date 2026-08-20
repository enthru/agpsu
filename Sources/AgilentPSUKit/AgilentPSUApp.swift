import SwiftUI
import AppKit
import PSUCore

struct AgilentPSUApp: App {
    @State private var model: AppModel
    @State private var menuBar: MenuBarReadout

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _menuBar = State(initialValue: MenuBarReadout(controller: model.controller))
        AppModel.current = model

        // Lets the app behave like a normal windowed application even when the
        // binary is run straight out of .build rather than from a bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("System DC Power Supply", id: "main") {
            MainView()
                .environment(model)
                // Settings are written on a debounce; quitting is the one moment
                // with no next turn of the run loop to wait for.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.saveNow()
                }
        }
        // The split gives each half the same width, so the default window is
        // sized for what the narrower half needs: two columns of controls. Drag
        // it smaller and they fold into one, which is what the grid is for.
        .defaultSize(width: 1280, height: 860)
        .commands {
            AppCommands(model: model)
        }

        // ⌘, — the standard place for preferences on macOS.
        Settings {
            SettingsView()
                .environment(model)
        }

        // SceneBuilder has no ForEach, so the three graph windows are declared
        // individually.
        Window("Voltage Graph", id: GraphKind.voltage.windowID) {
            GraphWindow(kind: .voltage).environment(model)
        }
        .defaultSize(width: 820, height: 520)

        Window("Current Graph", id: GraphKind.current.windowID) {
            GraphWindow(kind: .current).environment(model)
        }
        .defaultSize(width: 820, height: 520)

        Window("Power Graph", id: GraphKind.power.windowID) {
            GraphWindow(kind: .power).environment(model)
        }
        .defaultSize(width: 820, height: 520)

        // The output in the menu bar, for watching a supply from inside another
        // application. `isInserted` is the whole of the on/off switch: SwiftUI
        // adds and removes the item as the binding changes.
        MenuBarExtra(isInserted: $model.showsMenuBarReading) {
            MenuBarReadoutContent().environment(model)
        } label: {
            MenuBarLabel(readout: menuBar)
        }

        Window("Serial Connection Help", id: "help-serial") { SerialHelpView() }
        Window("General Help", id: "help-general") { GeneralHelpView() }
        Window("Credits", id: "credits") { CreditsView() }
    }
}

/// What ⌘S does, published by whichever window is frontmost: the main window
/// exports the event list, a graph window saves its samples.
struct ExportAction: Equatable {
    let title: String
    let perform: () -> Void

    static func == (lhs: ExportAction, rhs: ExportAction) -> Bool {
        lhs.title == rhs.title
    }
}

struct ExportActionKey: FocusedValueKey {
    typealias Value = ExportAction
}

extension FocusedValues {
    var exportAction: ExportAction? {
        get { self[ExportActionKey.self] }
        set { self[ExportActionKey.self] = newValue }
    }
}

/// The menu bar, carrying over the Windows menu structure — with the macOS
/// shortcuts a Mac user expects: ⌘, for Settings, ⌘S to save the front window,
/// ⌘O to pick a port, ⌘K to clear the list, ⌘0–⌘3 for the windows.
struct AppCommands: Commands {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.exportAction) private var exportAction

    private var controller: PSUController { model.controller }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        // ⌘S saves whatever the front window holds; without a window that can
        // export anything, the item stays disabled rather than disappearing.
        CommandGroup(replacing: .saveItem) {
            Button(exportAction?.title ?? "Export…") { exportAction?.perform() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(exportAction == nil)
        }

        CommandGroup(before: .windowList) {
            Button("Main Window") { openWindow(id: "main") }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }

        CommandMenu("Config") {
            Button("Select Serial Port…") { model.isConnectionSheetPresented = true }
                .keyboardShortcut("o", modifiers: .command)
            Button("Disconnect") { controller.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!controller.isConnected)
            Divider()
            Button("Reset Device") { controller.resetDevice() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!controller.isConnected)
            Divider()
            Button(model.simulatorPath == nil ? "Start Built-in Simulator" : "Simulator Running: \(model.simulatorPath ?? "")") {
                if let path = model.startSimulator() {
                    controller.append("Simulator on \(path) ")
                    model.isConnectionSheetPresented = true
                }
            }
            .disabled(model.simulatorPath != nil)
        }

        CommandMenu("Counters") {
            Button("Reset Runtime") { controller.resetRuntime() }
            Button("Reset Sampled Values") {
                controller.resetVoltageSamples()
                controller.resetCurrentSamples()
            }
            Button("Reset Volt Samples") { controller.resetVoltageSamples() }
            Button("Reset Curr Samples") { controller.resetCurrentSamples() }
            Divider()
            Menu("Update Speed Progress Bar") {
                ForEach([100.0, 1000.0, 10000.0], id: \.self) { maximum in
                    Button("Full at \(String(Int(maximum))) Samples") { controller.progressMaximum = maximum }
                }
            }
        }

        CommandMenu("Measurements") {
            Menu("Measure Current Range") {
                Button("Low Current Range (20mA)") { controller.setMeasurementRange(.low) }
                Button("High Current Range (>20mA)") { controller.setMeasurementRange(.high) }
            }
            Divider()
            Toggle("Measure Voltage", isOn: planBinding(\.measureVoltage))
            Toggle("Measure Current", isOn: planBinding(\.measureCurrent))
            Toggle("Get CV CC Dis Status", isOn: planBinding(\.readOperationStatus))
            Toggle("Get Protection Status", isOn: planBinding(\.readProtectionStatus))
            Toggle("Get Set Volt & Set Curr", isOn: planBinding(\.readSetValues))
            Toggle("Get Set OVP & OCP Values", isOn: planBinding(\.readProtectionLevels))
            Divider()
            rangeMenu("Voltage Auto Range", keyPath: \.voltageRange, unit: "V")
            rangeMenu("Current Auto Range", keyPath: \.currentRange, unit: "A")
            rangeMenu("Power Auto Range", keyPath: \.powerRange, unit: "W")
        }

        CommandMenu("Graphs") {
            Button("Show Voltage Graph") { openWindow(id: GraphKind.voltage.windowID) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Show Current Graph") { openWindow(id: GraphKind.current.windowID) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Show Power Graph") { openWindow(id: GraphKind.power.windowID) }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
            ForEach(GraphKind.allCases) { kind in
                Menu("\(kind.title) Graph Samples") {
                    ForEach(SampleBuffer.capacityChoices, id: \.self) { capacity in
                        Button(capacityLabel(capacity)) { model.setCapacity(capacity, for: kind) }
                    }
                }
            }
            Divider()
            ForEach(GraphKind.allCases) { kind in
                Menu("\(kind.title) Graph Settings") {
                    Toggle("Auto Axis", isOn: Binding(
                        get: { model.settings(for: kind).autoAxis },
                        set: { model.settings(for: kind).autoAxis = $0 }))
                    Toggle("Show Points", isOn: Binding(
                        get: { model.settings(for: kind).showPoints },
                        set: { model.settings(for: kind).showPoints = $0 }))
                    Divider()
                    Picker("X Axis", selection: Binding(
                        get: { model.settings(for: kind).xAxis },
                        set: { model.settings(for: kind).xAxis = $0 })) {
                        ForEach(GraphXAxis.allCases) { axis in
                            Text(axis.title).tag(axis)
                        }
                    }
                    if kind == .voltage {
                        Divider()
                        Toggle("Set Voltage Marker", isOn: Binding(
                            get: { model.settings(for: .voltage).showSetMarker },
                            set: { model.settings(for: .voltage).showSetMarker = $0 }))
                        Toggle("OVP Marker", isOn: Binding(
                            get: { model.settings(for: .voltage).showOVPMarker },
                            set: { model.settings(for: .voltage).showOVPMarker = $0 }))
                        Toggle("UVP Marker", isOn: Binding(
                            get: { model.settings(for: .voltage).showUVPMarker },
                            set: { model.settings(for: .voltage).showUVPMarker = $0 }))
                    }
                }
            }
        }

        // CommandsBuilder tops out at ten statements, so the last few menus
        // travel together.
        Group {
            CommandMenu("Output Panel") {
                Menu("Text Colour") {
                    ForEach(PanelColor.allCases) { color in
                        Button(color.title) { model.panelTextColor = color }
                    }
                }
                Menu("Panel Colour") {
                    ForEach([PanelColor.black, .white, .gray]) { color in
                        Button(color.title) { model.panelBackground = color }
                    }
                }
            }

            CommandMenu("Data Logger") {
                Toggle("Save Output to Text File", isOn: $model.controller.logOutputText)
                Toggle("Save Output to CSV File", isOn: $model.controller.logOutputCSV)
                Toggle("Save Status to Text File", isOn: $model.controller.logStatusText)
                Divider()
                Button("Choose Folder…", action: chooseLogFolder)
                Button("Reveal Folder in Finder") {
                    try? FileManager.default.createDirectory(at: controller.logDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(controller.logDirectory)
                }
            }

            CommandMenu("List") {
                Toggle("Auto Scroll", isOn: $model.controller.autoScroll)
                Toggle("Update List", isOn: $model.controller.updateList)
                Toggle("Add Meas Volt & Curr", isOn: $model.controller.addMeasurementsToList)
                Divider()
                Button("Clear List") { controller.clearEntries() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(controller.entries.isEmpty)
            }

            CommandGroup(replacing: .help) {
                Button("General Help") { openWindow(id: "help-general") }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
                Button("Serial Connection Help") { openWindow(id: "help-serial") }
                Button("Credits") { openWindow(id: "credits") }
            }
        }
    }

    // MARK: - Helpers

    private func planBinding(_ keyPath: WritableKeyPath<PSUPollPlan, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.pollPlan[keyPath: keyPath] },
            set: { controller.pollPlan[keyPath: keyPath] = $0 }
        )
    }

    @ViewBuilder
    private func rangeMenu(_ title: String, keyPath: ReferenceWritableKeyPath<PSUController, DisplayRange>, unit: String) -> some View {
        Menu(title) {
            Button("Disable") { controller[keyPath: keyPath].isAuto = false }
            Divider()
            ForEach(DisplayRange.thresholdChoices, id: \.self) { threshold in
                Button(thresholdLabel(threshold, unit: unit)) {
                    controller[keyPath: keyPath] = DisplayRange(isAuto: true, threshold: threshold)
                }
            }
        }
    }

    private func thresholdLabel(_ threshold: Double, unit: String) -> String {
        threshold >= 1
            ? "Below 1\(unit)"
            : "Below \(Int(threshold * 1000))m\(unit)"
    }

    private func capacityLabel(_ capacity: Int) -> String {
        capacity >= 1_000_000 ? "\(capacity / 1_000_000)M Samples" : "\(capacity / 1000)K Samples"
    }

    private func chooseLogFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = controller.logDirectory
        if panel.runModal() == .OK, let url = panel.url {
            controller.setLogDirectory(url)
            controller.append("Log folder: \(url.lastPathComponent) ")
        }
    }
}

/// Entry point used by the thin `AgilentPSU` executable target.
public func runAgilentPSU() {
    MainActor.assumeIsolated {
        AgilentPSUApp.main()
    }
}
