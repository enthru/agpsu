import SwiftUI
import PSUCore
import PSUSimulator

/// Named colours offered by the Output Panel and Graph Colours menus.
enum PanelColor: String, CaseIterable, Identifiable, Sendable {
    case green, blue, cyan, red, yellow, orange, white, black, pink, violet, gray

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .green: return (0.10, 0.80, 0.30)
        case .blue: return (0.16, 0.50, 0.95)
        case .cyan: return (0.10, 0.68, 0.94)
        case .red: return (0.92, 0.22, 0.20)
        case .yellow: return (0.95, 0.80, 0.10)
        case .orange: return (0.98, 0.55, 0.10)
        case .white: return (1.00, 1.00, 1.00)
        case .black: return (0.00, 0.00, 0.00)
        case .pink: return (0.96, 0.40, 0.65)
        case .violet: return (0.60, 0.35, 0.92)
        case .gray: return (0.35, 0.35, 0.35)
        }
    }

    var color: Color {
        let rgb = components
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Rec. 709 luminance, which is what decides whether black or white can be
    /// read on top of this colour.
    var luminance: Double {
        let rgb = components
        return 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    /// What to draw *on* this colour.
    ///
    /// Chart axis labels take the environment's foreground colour, which in
    /// dark mode is white — and the graph themes paint a white plot. The axis
    /// numbers were being drawn white on white and simply were not there. The
    /// plot is a chosen colour rather than a themed surface, so what goes on
    /// top of it has to be chosen from the same place rather than from the
    /// system appearance.
    var contrastingInk: Color {
        luminance > 0.5 ? .black : .white
    }
}

enum GraphKind: String, CaseIterable, Identifiable, Sendable {
    case voltage, current, power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voltage: return "Voltage"
        case .current: return "Current"
        case .power: return "Power"
        }
    }

    var unit: String {
        switch self {
        case .voltage: return "V"
        case .current: return "A"
        case .power: return "W"
        }
    }

    var windowID: String { "graph-" + rawValue }
}

enum GraphXAxis: String, CaseIterable, Identifiable, Sendable {
    case sampleNumber, time

    var id: String { rawValue }

    var title: String {
        self == .sampleNumber ? "Sample Number" : "Time"
    }
}

/// Per-graph appearance and marker settings, matching the Graph Colours and
/// Graph Settings menus of the Windows version.
@MainActor
@Observable
final class GraphSettings {
    let kind: GraphKind

    var curveColor: PanelColor
    var plotBackground: PanelColor = .white
    var figureBackground: PanelColor = .white
    var autoAxis = true
    var manualMinimum: Double = 0
    var manualMaximum: Double = 1
    var showSetMarker = true
    var showOVPMarker = false
    var showUVPMarker = false
    var showPoints = false
    var xAxis: GraphXAxis = .sampleNumber
    /// The last preset applied, so the Settings window can show which one is in use.
    private(set) var theme: GraphTheme = .standard

    init(kind: GraphKind) {
        self.kind = kind
        switch kind {
        case .voltage: curveColor = .cyan
        case .current: curveColor = .orange
        case .power: curveColor = .violet
        }
    }

    /// Everything about this graph worth remembering. The history size lives
    /// on the buffer rather than here, so it is passed in.
    func preferences(capacity: Int) -> Preferences.Graph {
        Preferences.Graph(curveColor: curveColor,
                          plotBackground: plotBackground,
                          figureBackground: figureBackground,
                          theme: theme,
                          autoAxis: autoAxis,
                          manualMinimum: manualMinimum,
                          manualMaximum: manualMaximum,
                          showSetMarker: showSetMarker,
                          showOVPMarker: showOVPMarker,
                          showUVPMarker: showUVPMarker,
                          showPoints: showPoints,
                          xAxis: xAxis,
                          capacity: capacity)
    }

    func apply(_ saved: Preferences.Graph) {
        // The theme first: it sets the two background colours, which the saved
        // values then override in case they were changed after it was picked.
        apply(theme: saved.theme)
        curveColor = saved.curveColor
        plotBackground = saved.plotBackground
        figureBackground = saved.figureBackground
        autoAxis = saved.autoAxis
        manualMinimum = saved.manualMinimum
        manualMaximum = saved.manualMaximum
        showSetMarker = saved.showSetMarker
        showOVPMarker = saved.showOVPMarker
        showUVPMarker = saved.showUVPMarker
        showPoints = saved.showPoints
        xAxis = saved.xAxis
    }

    /// The four presets from the original Graph Themes menu.
    func apply(theme: GraphTheme) {
        self.theme = theme
        switch theme {
        case .standard:
            plotBackground = .white
            figureBackground = .white
        case .black:
            plotBackground = .black
            figureBackground = .black
        case .blue:
            plotBackground = .white
            figureBackground = .blue
        case .gray:
            plotBackground = .white
            figureBackground = .gray
        case .grayBlack:
            plotBackground = .black
            figureBackground = .gray
        }
    }
}

enum GraphTheme: String, CaseIterable, Identifiable {
    case standard, black, blue, gray, grayBlack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default Theme"
        case .black: return "Black Theme"
        case .blue: return "Blue Theme"
        case .gray: return "Gray Theme"
        case .grayBlack: return "Gray Black Theme"
        }
    }
}

/// Application-wide state: the instrument controller plus everything that is
/// purely presentation (panel colours, graph settings, the built-in simulator).
@MainActor
@Observable
final class AppModel {
    /// The model the running application is using.
    ///
    /// App Intents arrive from outside the view hierarchy — there is no
    /// environment to read them out of — and the serial port is open in this one
    /// process, so there is exactly one model they could mean. Set by the app at
    /// launch and by nothing else: a test making its own model must not become
    /// the one Shortcuts talks to.
    static var current: AppModel?

    var controller = PSUController()

    /// Notification banners for the handful of events worth interrupting for.
    let alerts = AlertCentre()

    /// The output in the menu bar. Off costs nothing; on, it is the only way to
    /// watch a supply without giving it a window.
    var showsMenuBarReading = true

    /// The port that worked last time, offered again by the connection window.
    var lastConnection: SerialConfig?

    private let store: PreferenceStore
    private var saveTask: Task<Void, Never>?

    var panelTextColor: PanelColor = .cyan
    var panelBackground: PanelColor = .black

    var graphSettings: [GraphKind: GraphSettings] = [
        .voltage: GraphSettings(kind: .voltage),
        .current: GraphSettings(kind: .current),
        .power: GraphSettings(kind: .power),
    ]

    /// How many samples each graph keeps, held here as well as on the buffer.
    /// Reading it back out of the buffer would tie the settings writer to a
    /// value that changes on every sample.
    private(set) var capacities: [GraphKind: Int] = [:]

    var isConnectionSheetPresented = false

    private(set) var simulator: SimulatorServer?
    var simulatorPath: String? { simulator?.devicePath }

    /// - Parameter store: where settings are read from and written to. Tests
    ///   pass an ephemeral store so a run never touches the real ones. Resolved
    ///   inside the initialiser rather than as a default argument, which would
    ///   be evaluated outside the main actor.
    init(store: PreferenceStore? = nil) {
        self.store = store ?? .standard
        for kind in GraphKind.allCases {
            capacities[kind] = history(for: kind).capacity
        }
        if let saved = self.store.load() {
            apply(saved)
        }
        controller.alerts = alerts
        observeForSaving()
    }

    func settings(for kind: GraphKind) -> GraphSettings {
        graphSettings[kind] ?? GraphSettings(kind: kind)
    }

    func history(for kind: GraphKind) -> SampleBuffer {
        switch kind {
        case .voltage: return controller.voltageHistory
        case .current: return controller.currentHistory
        case .power: return controller.powerHistory
        }
    }

    /// The history size as a setting, without touching the buffer that changes
    /// several times a second.
    func capacity(for kind: GraphKind) -> Int {
        capacities[kind] ?? history(for: kind).capacity
    }

    func setCapacity(_ capacity: Int, for kind: GraphKind) {
        capacities[kind] = capacity
        switch kind {
        case .voltage: controller.voltageHistory.capacity = capacity
        case .current: controller.currentHistory.capacity = capacity
        case .power: controller.powerHistory.capacity = capacity
        }
    }

    // MARK: - Persistence

    /// The current state of everything worth remembering.
    ///
    /// Reading this is also what registers the observation: whatever it touches
    /// is what triggers a save when it changes. Live measurement state is
    /// deliberately absent — the histories grow several times a second and have
    /// no business waking the settings writer.
    var preferences: Preferences {
        var preferences = Preferences()

        preferences.panelTextColor = panelTextColor
        preferences.panelBackground = panelBackground
        preferences.graphs = Dictionary(uniqueKeysWithValues: GraphKind.allCases.map { kind in
            (kind.rawValue, settings(for: kind).preferences(capacity: capacity(for: kind)))
        })

        preferences.pollPlan = controller.pollPlan
        preferences.updateRate = controller.updateRate
        preferences.progressMaximum = controller.progressMaximum

        preferences.voltageRange = controller.voltageRange
        preferences.currentRange = controller.currentRange
        preferences.powerRange = controller.powerRange

        preferences.autoScroll = controller.autoScroll
        preferences.updateList = controller.updateList
        preferences.addMeasurementsToList = controller.addMeasurementsToList
        preferences.beeperEnabled = controller.beeperEnabled

        preferences.logOutputText = controller.logOutputText
        preferences.logOutputCSV = controller.logOutputCSV
        preferences.logStatusText = controller.logStatusText
        preferences.logDirectoryPath = controller.logDirectory.path

        preferences.alerts = Preferences.Alerts(isEnabled: alerts.isEnabled,
                                                kinds: alerts.kinds,
                                                onlyWhenInBackground: alerts.onlyWhenInBackground)
        preferences.showsMenuBarReading = showsMenuBarReading
        preferences.lastConnection = lastConnection

        return preferences
    }

    func apply(_ preferences: Preferences) {
        panelTextColor = preferences.panelTextColor
        panelBackground = preferences.panelBackground

        for kind in GraphKind.allCases {
            guard let saved = preferences.graphs[kind.rawValue] else { continue }
            settings(for: kind).apply(saved)
            setCapacity(saved.capacity, for: kind)
        }

        controller.pollPlan = preferences.pollPlan
        controller.updateRate = preferences.updateRate
        controller.progressMaximum = preferences.progressMaximum

        controller.voltageRange = preferences.voltageRange
        controller.currentRange = preferences.currentRange
        controller.powerRange = preferences.powerRange

        controller.autoScroll = preferences.autoScroll
        controller.updateList = preferences.updateList
        controller.addMeasurementsToList = preferences.addMeasurementsToList
        controller.beeperEnabled = preferences.beeperEnabled

        controller.logOutputText = preferences.logOutputText
        controller.logOutputCSV = preferences.logOutputCSV
        controller.logStatusText = preferences.logStatusText
        if let path = preferences.logDirectoryPath {
            controller.setLogDirectory(URL(fileURLWithPath: path, isDirectory: true))
        }

        alerts.kinds = preferences.alerts.kinds
        alerts.onlyWhenInBackground = preferences.alerts.onlyWhenInBackground
        // Last, and only if it was on: assigning `isEnabled` re-asks the system,
        // which is silent once an answer exists — anybody with this saved has
        // been asked already — and refreshes what Settings reports, so a
        // permission revoked in System Settings shows up here rather than in a
        // banner that never arrives.
        if preferences.alerts.isEnabled { alerts.isEnabled = true }
        showsMenuBarReading = preferences.showsMenuBarReading
        lastConnection = preferences.lastConnection
    }

    /// Watches everything `preferences` reads and re-arms itself after each
    /// change. `onChange` runs before the new value is in place, hence the hop
    /// to the next turn of the main actor before anything is collected.
    private func observeForSaving() {
        withObservationTracking {
            _ = preferences
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleSave()
                self.observeForSaving()
            }
        }
    }

    /// Dragging a stepper changes a setting many times a second; there is no
    /// reason for the disk to hear about all of them.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes immediately — on quit, where there is no next turn to wait for.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        store.save(preferences)
    }

    /// Starts the built-in SCPI simulator and returns the device path to connect
    /// to, so the whole application can be exercised without hardware.
    @discardableResult
    func startSimulator() -> String? {
        if let simulator { return simulator.devicePath }
        do {
            let server = try SimulatorServer()
            server.start()
            simulator = server
            return server.devicePath
        } catch {
            controller.append("Simulator failed: \(error.localizedDescription)")
            return nil
        }
    }

    func stopSimulator() {
        simulator?.stop()
        simulator = nil
    }
}
