import SwiftUI
import AppKit
import PSUCore

/// The Settings window behind ⌘, — the standard macOS home for everything that
/// is a preference rather than an action. The menus keep their entries; both
/// drive the same `AppModel`, so nothing is duplicated but the presentation.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PollingSettings()
                .tabItem { Label("Polling", systemImage: "waveform.path.ecg") }
            GraphsSettings()
                .tabItem { Label("Graphs", systemImage: "chart.xyaxis.line") }
            LoggingSettings()
                .tabItem { Label("Logging", systemImage: "doc.text") }
        }
        .environment(model)
        .frame(width: 560, height: 420)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var controller = model.controller

        Form {
            Section("Output Panel") {
                colorPicker("Text colour", selection: $model.panelTextColor)
                colorPicker("Panel colour", selection: $model.panelBackground,
                            choices: [.black, .white, .gray])
            }

            Section("Event List") {
                Toggle("Auto scroll", isOn: $controller.autoScroll)
                Toggle("Update list", isOn: $controller.updateList)
                Toggle("Add measured volt & curr", isOn: $controller.addMeasurementsToList)
            }

            Section("Status Bar") {
                Picker("Update speed bar full at", selection: $controller.progressMaximum) {
                    Text("100 samples").tag(100.0)
                    Text("1000 samples").tag(1000.0)
                    Text("10000 samples").tag(10000.0)
                }
            }

            Section("Reading Format") {
                rangePicker("Voltage auto range", value: $controller.voltageRange, unit: "V")
                rangePicker("Current auto range", value: $controller.currentRange, unit: "A")
                rangePicker("Power auto range", value: $controller.powerRange, unit: "W")
            }

            Section("Menu Bar") {
                Toggle("Show the output in the menu bar", isOn: $model.showsMenuBarReading)
                Text("Volts and amps, updated twice a second — as fast as a number in a menu bar can be read. The menu behind it carries the set points, an output-off switch and the way back to the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Alerts") {
                alertSettings
            }
        }
        .formStyle(.grouped)
    }

    /// Notification banners. The kinds are listed rather than rolled into one
    /// switch because they are not the same kind of event: a protection trip has
    /// already shut the output down, the crossover into constant current is a
    /// warning that something under test is drawing more than it should, and a
    /// lost connection ends the session.
    @ViewBuilder
    private var alertSettings: some View {
        @Bindable var alerts = model.alerts

        Toggle("Notify with a banner", isOn: $alerts.isEnabled)

        if alerts.isEnabled {
            ForEach(PSUAlert.Kind.allCases, id: \.self) { kind in
                Toggle(isOn: Binding(get: { alerts.kinds.contains(kind) },
                                     set: { wanted in
                                         if wanted { alerts.kinds.insert(kind) } else { alerts.kinds.remove(kind) }
                                     })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.title)
                        Text(kind.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 18)
            }

            Toggle("Only while another app is in front", isOn: $alerts.onlyWhenInBackground)
                .padding(.leading, 18)

            if let explanation = alerts.authorization.explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// One row per display range: "off", or the threshold below which the
    /// reading switches to milli-units.
    private func rangePicker(_ title: String, value: Binding<DisplayRange>, unit: String) -> some View {
        Picker(title, selection: Binding(
            get: { value.wrappedValue.isAuto ? value.wrappedValue.threshold : 0 },
            set: { value.wrappedValue = $0 == 0 ? DisplayRange(isAuto: false) : DisplayRange(isAuto: true, threshold: $0) }
        )) {
            Text("Disabled").tag(0.0)
            ForEach(DisplayRange.thresholdChoices, id: \.self) { threshold in
                Text(threshold >= 1 ? "Below 1\(unit)" : "Below \(Int(threshold * 1000))m\(unit)")
                    .tag(threshold)
            }
        }
    }
}

// MARK: - Polling

struct PollingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var controller = model.controller

        Form {
            Section("Update Rate") {
                HStack {
                    TextField("Seconds between passes", value: $controller.updateRate,
                              format: .number.precision(.fractionLength(0...3)))
                        .frame(width: 80)
                    Stepper("", value: $controller.updateRate, in: 0.05...3600, step: 0.05)
                        .labelsHidden()
                }
                Text("Each pass asks the supply only for the values ticked below, so fewer readings mean a faster loop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Read Each Pass") {
                Toggle("Measure voltage", isOn: $controller.pollPlan.measureVoltage)
                Toggle("Measure current", isOn: $controller.pollPlan.measureCurrent)
                Toggle("CV / CC / Dis status", isOn: $controller.pollPlan.readOperationStatus)
                Toggle("Protection status", isOn: $controller.pollPlan.readProtectionStatus)
                Toggle("Set volt & set curr", isOn: $controller.pollPlan.readSetValues)
                Toggle("Set OVP & OCP values", isOn: $controller.pollPlan.readProtectionLevels)
            }

            Section("Measurement") {
                Picker("Current range", selection: Binding(
                    get: { controller.measurementRange },
                    set: { controller.setMeasurementRange($0) }
                )) {
                    Text("Low (20mA)").tag(CurrentMeasurementRange.low)
                    Text("High (>20mA)").tag(CurrentMeasurementRange.high)
                }
                .disabled(!controller.isConnected)

                Toggle("Beep when a protection trips", isOn: $controller.beeperEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Graphs

struct GraphsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var kind: GraphKind = .voltage

    var body: some View {
        @Bindable var settings = model.settings(for: kind)

        VStack(spacing: 0) {
            Picker("", selection: $kind) {
                ForEach(GraphKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Form {
                Section("Colours") {
                    colorPicker("Curve", selection: $settings.curveColor)
                    colorPicker("Plot background", selection: $settings.plotBackground)
                    colorPicker("Figure background", selection: $settings.figureBackground)
                    Picker("Theme", selection: Binding(
                        get: { settings.theme },
                        set: { settings.apply(theme: $0) }
                    )) {
                        ForEach(GraphTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                }

                Section("Axes") {
                    Picker("X axis", selection: $settings.xAxis) {
                        ForEach(GraphXAxis.allCases) { axis in
                            Text(axis.title).tag(axis)
                        }
                    }
                    Toggle("Auto Y axis", isOn: $settings.autoAxis)
                    if !settings.autoAxis {
                        HStack {
                            Text("Y range")
                            TextField("Min", value: $settings.manualMinimum, format: .number)
                                .frame(width: 70)
                            TextField("Max", value: $settings.manualMaximum, format: .number)
                                .frame(width: 70)
                        }
                    }
                    Toggle("Show points", isOn: $settings.showPoints)
                }

                if kind == .voltage {
                    Section("Markers") {
                        Toggle("Set voltage", isOn: $settings.showSetMarker)
                        Toggle("OVP level", isOn: $settings.showOVPMarker)
                        Toggle("UVP level", isOn: $settings.showUVPMarker)
                    }
                }

                Section("History") {
                    Picker("Keep at most", selection: Binding(
                        get: { model.capacity(for: kind) },
                        set: { model.setCapacity($0, for: kind) }
                    )) {
                        ForEach(SampleBuffer.capacityChoices, id: \.self) { capacity in
                            Text(capacity >= 1_000_000
                                 ? "\(capacity / 1_000_000)M samples"
                                 : "\(capacity / 1000)K samples")
                                .tag(capacity)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Logging

struct LoggingSettings: View {
    @Environment(AppModel.self) private var model

    private var controller: PSUController { model.controller }

    var body: some View {
        @Bindable var controller = model.controller

        Form {
            Section("Write While Connected") {
                Toggle("Output to text file", isOn: $controller.logOutputText)
                Toggle("Output to CSV file", isOn: $controller.logOutputCSV)
                Toggle("Status to text file", isOn: $controller.logStatusText)
            }

            Section("Folder") {
                LabeledContent("Location") {
                    Text(controller.logDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…", action: chooseFolder)
                    Button("Reveal in Finder", action: revealFolder)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = controller.logDirectory
        if panel.runModal() == .OK, let url = panel.url {
            controller.setLogDirectory(url)
            controller.append("Log folder: \(url.lastPathComponent) ")
        }
    }

    private func revealFolder() {
        try? FileManager.default.createDirectory(at: controller.logDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(controller.logDirectory)
    }
}

// MARK: - Shared

/// A colour row that shows the swatch as well as the name.
@ViewBuilder
private func colorPicker(_ title: String,
                         selection: Binding<PanelColor>,
                         choices: [PanelColor] = PanelColor.allCases) -> some View {
    Picker(title, selection: selection) {
        ForEach(choices) { choice in
            Label {
                Text(choice.title)
            } icon: {
                Circle().fill(choice.color)
            }
            .tag(choice)
        }
    }
}
