import Foundation
import PSUCore

/// Everything the application remembers between launches.
///
/// Decoding is deliberately forgiving. A preferences file written by an older
/// build is missing whatever has been added since, and the honest behaviour is
/// to keep what is there and default the rest — not to throw the lot away
/// because one key is new. Scalars fall back individually; a group whose shape
/// has changed falls back as a group.
///
/// Nothing here is sent to the supply at launch. Restoring a *panel* is not the
/// same as restoring an *output*, and a bench supply that comes up putting
/// yesterday's volts across whatever is now on the bench would be a hazard, not
/// a convenience. The set values go down when you connect and ask for them.
struct Preferences: Codable, Equatable {

    struct Graph: Codable, Equatable {
        var curveColor: PanelColor = .cyan
        var plotBackground: PanelColor = .white
        var figureBackground: PanelColor = .white
        var theme: GraphTheme = .standard
        var autoAxis = true
        var manualMinimum: Double = 0
        var manualMaximum: Double = 1
        var showSetMarker = true
        var showOVPMarker = false
        var showUVPMarker = false
        var showPoints = false
        var xAxis: GraphXAxis = .sampleNumber
        var capacity: Int = 50_000
    }

    /// Notification banners. Off until asked for: an application that demands
    /// permission to interrupt you on first launch, before it has measured
    /// anything, has not earned it.
    struct Alerts: Codable, Equatable {
        var isEnabled = false
        var kinds: Set<PSUAlert.Kind> = [.protectionTripped, .connectionLost]
        /// Only when the app is not the one you are looking at.
        var onlyWhenInBackground = true
    }

    var version = 1

    var panelTextColor: PanelColor = .cyan
    var panelBackground: PanelColor = .black

    /// One entry per graph, keyed by `GraphKind.rawValue`.
    var graphs: [String: Graph] = [:]

    var pollPlan = PSUPollPlan()
    var updateRate: TimeInterval = 1.0
    var progressMaximum: Double = 100

    var voltageRange = DisplayRange()
    var currentRange = DisplayRange()
    var powerRange = DisplayRange()

    var autoScroll = true
    var updateList = true
    var addMeasurementsToList = false
    var beeperEnabled = true

    var logOutputText = false
    var logOutputCSV = false
    var logStatusText = false
    var logDirectoryPath: String?

    var alerts = Alerts()
    /// The output in the menu bar, for glancing at from another application.
    var showsMenuBarReading = true

    /// The port that worked last time, so reconnecting is one click.
    var lastConnection: SerialConfig?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()

        // `try?` of an optional decode gives a double optional: the outer nil
        // means the value was there but the wrong shape, the inner that the key
        // was absent. Both mean "use the default".
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        func optional<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }

        version = value(.version, defaults.version)
        panelTextColor = value(.panelTextColor, defaults.panelTextColor)
        panelBackground = value(.panelBackground, defaults.panelBackground)
        graphs = value(.graphs, defaults.graphs)

        pollPlan = value(.pollPlan, defaults.pollPlan)
        updateRate = value(.updateRate, defaults.updateRate)
        progressMaximum = value(.progressMaximum, defaults.progressMaximum)

        voltageRange = value(.voltageRange, defaults.voltageRange)
        currentRange = value(.currentRange, defaults.currentRange)
        powerRange = value(.powerRange, defaults.powerRange)

        autoScroll = value(.autoScroll, defaults.autoScroll)
        updateList = value(.updateList, defaults.updateList)
        addMeasurementsToList = value(.addMeasurementsToList, defaults.addMeasurementsToList)
        beeperEnabled = value(.beeperEnabled, defaults.beeperEnabled)

        logOutputText = value(.logOutputText, defaults.logOutputText)
        logOutputCSV = value(.logOutputCSV, defaults.logOutputCSV)
        logStatusText = value(.logStatusText, defaults.logStatusText)
        logDirectoryPath = optional(.logDirectoryPath, String.self)

        alerts = value(.alerts, defaults.alerts)
        showsMenuBarReading = value(.showsMenuBarReading, defaults.showsMenuBarReading)
        lastConnection = optional(.lastConnection, SerialConfig.self)
    }
}

/// Where preferences live. Backed by `UserDefaults` in the application and by
/// memory in tests, so a test run never touches the user's real settings.
@MainActor
final class PreferenceStore {
    static let key = "com.agpsu.preferences"
    static let standard = PreferenceStore(defaults: .standard)
    static func ephemeral() -> PreferenceStore { PreferenceStore(defaults: nil) }

    private let defaults: UserDefaults?
    private var memory: Data?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func load() -> Preferences? {
        guard let data = defaults?.data(forKey: Self.key) ?? memory else { return nil }
        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    func save(_ preferences: Preferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        if let defaults {
            defaults.set(data, forKey: Self.key)
        } else {
            memory = data
        }
    }

    func clear() {
        defaults?.removeObject(forKey: Self.key)
        memory = nil
    }
}

extension PanelColor: Codable {}
extension GraphTheme: Codable {}
extension GraphXAxis: Codable {}
