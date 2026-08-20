import XCTest
@testable import PSUCore
@testable import PSUSimulator

/// Drives `PSUController` — the object the UI binds to — against the simulator
/// over a real serial connection, covering the polling loop, command queue,
/// soft protections, graph histories and file logging.
@MainActor
final class ControllerTests: XCTestCase {

    private var server: SimulatorServer!
    private var controller: PSUController!

    override func setUp() async throws {
        server = try SimulatorServer()
        server.start()

        controller = PSUController()
        controller.beeperEnabled = false
        controller.updateRate = 0.05

        let config = SerialConfig(path: server.devicePath, readTimeout: 2, writeTimeout: 2)
        let identity = try ConnectionProbe.identify(config: config)
        controller.connect(config: config, identity: identity)
    }

    override func tearDown() async throws {
        controller?.disconnect()
        server?.stop()
        controller = nil
        server = nil
    }

    /// Waits for a condition the polling loop is expected to reach.
    private func eventually(_ description: String,
                            timeout: TimeInterval = 5,
                            _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    func testConnectsAndReportsDeviceDetails() async throws {
        XCTAssertTrue(controller.isConnected)
        XCTAssertEqual(controller.identity?.model, "HP6632B")
        XCTAssertEqual(controller.deviceTitle, "HP6632B System DC Power Supply")
    }

    func testPollingLoopDeliversReadings() async throws {
        server.simulatedDevice.loadResistance = 100
        controller.setVoltage(5, inMillivolts: false)
        controller.setCurrent(1, inMilliamps: false)
        controller.toggleOutput()

        try await eventually("a constant-voltage reading") {
            self.controller.outputMode == .constantVoltage
        }

        XCTAssertEqual(controller.measuredVoltage, 5.0, accuracy: 0.05)
        XCTAssertEqual(controller.measuredCurrent, 0.05, accuracy: 0.005)
        XCTAssertEqual(controller.measuredPower, 0.25, accuracy: 0.02)
        XCTAssertTrue(controller.isOutputEnabled)
        XCTAssertGreaterThan(controller.voltageSampleCount, 0)
    }

    func testSetPointsAreReadBackFromTheSupply() async throws {
        controller.setVoltage(4190, inMillivolts: true)   // 4.19 V entered as mV
        try await eventually("the set voltage read-back") {
            (self.controller.setVoltageReadback ?? 0) > 4.18
        }
        XCTAssertEqual(controller.setVoltageReadback!, 4.19, accuracy: 0.001)
    }

    func testGraphHistoriesGrowWhileConnected() async throws {
        server.simulatedDevice.loadResistance = 100
        controller.setVoltage(3, inMillivolts: false)
        controller.setCurrent(1, inMilliamps: false)
        controller.toggleOutput()

        try await eventually("several graph samples") {
            self.controller.voltageHistory.samples.count >= 3
                && self.controller.currentHistory.samples.count >= 3
                && self.controller.powerHistory.samples.count >= 3
        }
        XCTAssertEqual(controller.voltageHistory.latest!.value, 3.0, accuracy: 0.05)
    }

    func testSoftUnderVoltageProtectionShutsTheOutputDown() async throws {
        server.simulatedDevice.loadResistance = 100
        controller.setVoltage(1, inMillivolts: false)
        controller.setCurrent(1, inMilliamps: false)
        controller.toggleOutput()
        try await eventually("output regulating") { self.controller.outputMode == .constantVoltage }

        // Demand more than the supply is producing: UVP must trip.
        controller.setUVP(5)

        try await eventually("UVP to trip") {
            self.controller.entries.contains { $0.text.hasPrefix("UVP Tripped") }
        }
        try await eventually("the output to go off") { self.controller.outputMode == .disabled }
        XCTAssertNil(controller.uvpLevel, "the protection disarms itself once it has fired")
    }

    func testOverVoltageProtectionTripIsReported() async throws {
        controller.setOVP(2.0)
        try await eventually("OVP read-back") { (self.controller.ovpLevel ?? 99) <= 2.0 }

        controller.setVoltage(5, inMillivolts: false)
        controller.setCurrent(1, inMilliamps: false)
        controller.toggleOutput()

        try await eventually("the OV trip to be logged") {
            self.controller.entries.contains { $0.text.hasPrefix("OV Tripped") }
        }
        XCTAssertFalse(controller.protection.isClear)

        controller.setVoltage(1, inMillivolts: false)
        controller.clearProtection()
        try await eventually("protection to clear") { self.controller.protection.isClear }
    }

    func testRejectsAnOVPAboveTheSupplyRating() async throws {
        controller.setOVP(500)
        XCTAssertTrue(controller.entries.contains { $0.text.hasPrefix("Invalid OVP value") })
    }

    func testOCPToggleIsReadBack() async throws {
        controller.toggleOCP()
        try await eventually("OCP enabled") { self.controller.ocpEnabled == true }
        controller.toggleOCP()
        try await eventually("OCP disabled") { self.controller.ocpEnabled == false }
    }

    func testDisablingAMeasurementBlanksItsReading() async throws {
        server.simulatedDevice.loadResistance = 100
        controller.setVoltage(4, inMillivolts: false)
        controller.setCurrent(1, inMilliamps: false)
        controller.toggleOutput()
        try await eventually("a voltage reading") { self.controller.voltageIsValid }

        controller.pollPlan.measureVoltage = false
        try await eventually("the voltage readout to blank") { !self.controller.voltageIsValid }
        XCTAssertEqual(controller.measuredVoltage, 0)
        XCTAssertEqual(controller.measuredPower, 0, "power needs both readings")
    }

    func testPausingTheListStopsNewEntries() async throws {
        controller.updateList = false
        let before = controller.entries.count
        controller.append("should not appear")
        XCTAssertEqual(controller.entries.count, before)

        controller.updateList = true
        controller.append("should appear")
        XCTAssertEqual(controller.entries.count, before + 1)
    }

    func testWritesMeasurementLogFiles() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agpsu-test-\(UUID().uuidString)")
        controller.setLogDirectory(directory)
        controller.logOutputCSV = true

        server.simulatedDevice.loadResistance = 100
        controller.setVoltage(4, inMillivolts: false)
        controller.setCurrent(1, inMilliamps: false)
        controller.toggleOutput()

        try await eventually("a log file on disk") {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return files.contains { $0.hasSuffix(".csv") }
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let name = try XCTUnwrap(files.first { $0.hasSuffix(".csv") })
        XCTAssertTrue(name.contains("HP6632B"), "file name carries the model, as on Windows")

        let contents = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        let firstLine = try XCTUnwrap(contents.split(separator: "\n").first)
        XCTAssertEqual(firstLine.split(separator: ",").count, 3, "date, voltage, current")

        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Alerts

    func testAProtectionTripRaisesABanner() async throws {
        let presenter = RecordingPresenter()
        controller.alerts = presenter

        controller.setOVP(2.0)
        try await eventually("OVP read-back") { (self.controller.ovpLevel ?? 99) <= 2.0 }
        controller.setVoltage(5, inMillivolts: false)
        controller.setCurrent(1, inMilliamps: false)
        controller.toggleOutput()

        try await eventually("the banner") { presenter.alerts.contains { $0.kind == .protectionTripped } }
        let alert = try XCTUnwrap(presenter.alerts.first { $0.kind == .protectionTripped })
        XCTAssertTrue(alert.title.contains("OV"), "the banner names the protection, not just 'a fault'")
        XCTAssertTrue(alert.body.contains("HP6632B"))
    }

    func testTheCrossoverIntoCurrentLimitIsAnnouncedOnce() async throws {
        let presenter = RecordingPresenter()
        controller.alerts = presenter

        // 5 V into 10 Ω wants half an amp; the limit allows a tenth of one.
        server.simulatedDevice.loadResistance = 10
        controller.setVoltage(5, inMillivolts: false)
        controller.setCurrent(0.1, inMilliamps: false)
        controller.toggleOutput()

        try await eventually("constant current") { self.controller.outputMode.isCurrentLimited }
        try await eventually("the banner") { !presenter.alerts.isEmpty }

        // Several more polling passes in the same state.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(presenter.alerts.filter { $0.kind == .wentToConstantCurrent }.count, 1,
                       "the edge, not the state — a supply can sit in CC for hours")
    }

    func testASoftTripAlertsTooEvenThoughTheSupplyKnowsNothingAboutIt() async throws {
        let presenter = RecordingPresenter()
        controller.alerts = presenter

        server.simulatedDevice.loadResistance = 100
        controller.setVoltage(1, inMillivolts: false)
        controller.setCurrent(1, inMilliamps: false)
        controller.toggleOutput()
        try await eventually("output regulating") { self.controller.outputMode == .constantVoltage }
        controller.setUVP(5)

        try await eventually("the banner") { !presenter.alerts.isEmpty }
        XCTAssertEqual(presenter.alerts.first?.kind, .protectionTripped)
        XCTAssertTrue(presenter.alerts.first!.title.hasPrefix("UVP"))
    }

    func testAnAlertNobodyAskedForIsNeverEvenBuilt() async throws {
        let presenter = RecordingPresenter()
        presenter.wanted = []
        controller.alerts = presenter

        server.simulatedDevice.loadResistance = 10
        controller.setVoltage(5, inMillivolts: false)
        controller.setCurrent(0.1, inMilliamps: false)
        controller.toggleOutput()
        try await eventually("constant current") { self.controller.outputMode.isCurrentLimited }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(presenter.alerts.isEmpty)
        XCTAssertGreaterThan(presenter.questions, 0, "asked first, built never")
    }

    func testResettingTheHistoryClearsEveryGraphAndCounter() async throws {
        server.simulatedDevice.loadResistance = 100
        controller.setVoltage(3, inMillivolts: false)
        controller.setCurrent(1, inMilliamps: false)
        controller.toggleOutput()
        try await eventually("samples in all three graphs") {
            self.controller.powerHistory.samples.count >= 3
        }

        controller.resetHistory()
        XCTAssertTrue(controller.voltageHistory.isEmpty)
        XCTAssertTrue(controller.currentHistory.isEmpty)
        XCTAssertTrue(controller.powerHistory.isEmpty)
        XCTAssertEqual(controller.voltageHistory.totalRecorded, 0)
        XCTAssertEqual(controller.voltageSampleCount, 0)
        XCTAssertEqual(controller.currentSampleCount, 0)
    }

    func testDisconnectStopsPolling() async throws {
        try await eventually("at least one polling pass") { self.controller.voltageSampleCount > 0 }
        controller.disconnect()

        let count = controller.voltageSampleCount
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.voltageSampleCount, count)
        XCTAssertFalse(controller.isConnected)
    }
}


/// Stands in for the notification centre: records what would have been posted,
/// and can refuse a kind the way the Settings window does.
@MainActor
private final class RecordingPresenter: AlertPresenter {
    var wanted: Set<PSUAlert.Kind> = Set(PSUAlert.Kind.allCases)
    private(set) var alerts: [PSUAlert] = []
    private(set) var questions = 0

    func wantsAlert(of kind: PSUAlert.Kind) -> Bool {
        questions += 1
        return wanted.contains(kind)
    }

    func present(_ alert: PSUAlert) {
        alerts.append(alert)
    }
}
