import XCTest
@testable import PSUCore
@testable import AgilentPSUKit

/// Settings survive a restart — and, more importantly, survive the *next*
/// version of the application reading a file the current one wrote.
@MainActor
final class PreferencesTests: XCTestCase {

    func testEverythingTheUserChangedComesBack() async throws {
        let store = PreferenceStore.ephemeral()

        let first = AppModel(store: store)
        first.panelTextColor = .green
        first.panelBackground = .gray
        first.settings(for: .voltage).curveColor = .pink
        first.settings(for: .voltage).xAxis = .time
        first.settings(for: .voltage).showOVPMarker = true
        first.settings(for: .voltage).autoAxis = false
        first.settings(for: .voltage).manualMinimum = -1.5
        first.settings(for: .current).apply(theme: .grayBlack)
        first.setCapacity(500_000, for: .power)
        first.controller.updateRate = 0.25
        first.controller.progressMaximum = 1000
        first.controller.pollPlan.readProtectionLevels = false
        first.controller.voltageRange = DisplayRange(isAuto: true, threshold: 0.4)
        first.controller.currentRange = DisplayRange(isAuto: false)
        first.controller.logOutputCSV = true
        first.controller.addMeasurementsToList = true
        first.controller.beeperEnabled = false
        first.lastConnection = SerialConfig(path: "/dev/cu.usbserial-1410", baudRate: 4800, parity: .odd)
        first.saveNow()

        let second = AppModel(store: store)
        XCTAssertEqual(second.panelTextColor, .green)
        XCTAssertEqual(second.panelBackground, .gray)
        XCTAssertEqual(second.settings(for: .voltage).curveColor, .pink)
        XCTAssertEqual(second.settings(for: .voltage).xAxis, .time)
        XCTAssertTrue(second.settings(for: .voltage).showOVPMarker)
        XCTAssertFalse(second.settings(for: .voltage).autoAxis)
        XCTAssertEqual(second.settings(for: .voltage).manualMinimum, -1.5)
        XCTAssertEqual(second.settings(for: .current).theme, .grayBlack)
        XCTAssertEqual(second.settings(for: .current).plotBackground, .black, "the theme brought its colours with it")
        XCTAssertEqual(second.capacity(for: .power), 500_000)
        XCTAssertEqual(second.history(for: .power).capacity, 500_000, "and reaches the buffer")
        XCTAssertEqual(second.controller.updateRate, 0.25)
        XCTAssertEqual(second.controller.progressMaximum, 1000)
        XCTAssertFalse(second.controller.pollPlan.readProtectionLevels)
        XCTAssertEqual(second.controller.voltageRange.threshold, 0.4)
        XCTAssertFalse(second.controller.currentRange.isAuto)
        XCTAssertTrue(second.controller.logOutputCSV)
        XCTAssertTrue(second.controller.addMeasurementsToList)
        XCTAssertFalse(second.controller.beeperEnabled)
        XCTAssertEqual(second.lastConnection?.path, "/dev/cu.usbserial-1410")
        XCTAssertEqual(second.lastConnection?.baudRate, 4800)
        XCTAssertEqual(second.lastConnection?.parity, .odd)
    }

    /// Restoring a panel is not the same as restoring an output. A supply that
    /// came up putting yesterday's volts across whatever is now on the bench
    /// would be a hazard, not a convenience.
    func testNothingIsSentToTheSupplyAtLaunch() {
        let store = PreferenceStore.ephemeral()
        let first = AppModel(store: store)
        first.controller.setVoltage(4.19, inMillivolts: false)
        first.saveNow()

        let second = AppModel(store: store)
        XCTAssertFalse(second.controller.isConnected)
        XCTAssertNil(second.controller.setVoltageReadback, "no set point is remembered, let alone re-sent")
        XCTAssertFalse(second.controller.isOutputEnabled)
        XCTAssertNil(second.preferences.lastConnection, "and it does not reconnect on its own either")
    }

    /// A file written by an older build is missing whatever has been added
    /// since. Keeping what is there beats throwing the lot away.
    func testAFileMissingNewerKeysKeepsWhatItDoesHave() throws {
        let json = """
        {"version":1,"panelTextColor":"pink","updateRate":0.5}
        """
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))

        XCTAssertEqual(preferences.panelTextColor, .pink)
        XCTAssertEqual(preferences.updateRate, 0.5)
        XCTAssertTrue(preferences.autoScroll, "absent keys take their defaults")
        XCTAssertTrue(preferences.pollPlan.measureVoltage)
        XCTAssertNil(preferences.lastConnection)
    }

    /// A key that is present but the wrong shape falls back rather than taking
    /// the whole file down with it.
    func testAMalformedGroupFallsBackToItsDefault() throws {
        let json = """
        {"panelBackground":"gray","graphs":"this used to be an object","progressMaximum":4242}
        """
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))

        XCTAssertEqual(preferences.panelBackground, .gray)
        XCTAssertEqual(preferences.progressMaximum, 4242)
        XCTAssertTrue(preferences.graphs.isEmpty)
    }

    func testGarbageInTheStoreIsIgnoredRatherThanCrashing() {
        // A named suite so the test writes somewhere of its own, and removes it
        // again rather than leaving litter in the user's preferences.
        let suite = "agpsu-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: PreferenceStore.key)

        let store = PreferenceStore(defaults: defaults)
        XCTAssertNil(store.load())

        let model = AppModel(store: store)
        XCTAssertEqual(model.panelTextColor, .cyan, "defaults, not a crash")
    }

    /// The observation-driven saver has to notice a change made anywhere, not
    /// only through the paths that happen to call `saveNow`.
    func testAChangeIsWrittenWithoutAnybodyAskingItTo() async throws {
        let store = PreferenceStore.ephemeral()
        let model = AppModel(store: store)

        model.controller.progressMaximum = 777
        // Writes are debounced; a stepper held down should not mean sixty writes.
        XCTAssertNil(store.load(), "not written immediately")

        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(store.load()?.progressMaximum, 777)
    }

    /// Live measurement state changes several times a second and has no business
    /// waking the settings writer.
    func testReadingsDoNotTriggerSaves() async throws {
        let store = PreferenceStore.ephemeral()
        let model = AppModel(store: store)

        for index in 0..<500 {
            model.controller.voltageHistory.append(value: Double(index), at: Date())
            model.controller.powerHistory.append(value: Double(index), at: Date())
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertNil(store.load(), "the history is not a setting")
    }

    func testCollectingAndApplyingAreSymmetric() {
        let model = AppModel(store: .ephemeral())
        let original = model.preferences

        model.apply(original)
        XCTAssertEqual(model.preferences, original)
    }
}
