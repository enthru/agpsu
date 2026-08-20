import XCTest
import AppIntents
@testable import PSUCore
@testable import PSUSimulator
@testable import AgilentPSUKit

/// The three ways the app reaches out of its own window: a banner, the menu bar
/// and Shortcuts.
@MainActor
final class AutomationTests: XCTestCase {

    // MARK: - Banners

    /// Builds a centre that never touches the real notification centre.
    private func makeCentre(appIsActive: Bool = false) -> (AlertCentre, () -> [PSUAlert]) {
        var delivered: [PSUAlert] = []
        let centre = AlertCentre(deliver: { delivered.append($0) },
                                 requestPermission: { $0(.granted) },
                                 appIsActive: { appIsActive })
        return (centre, { delivered })
    }

    func testNothingIsDeliveredUntilSomebodyAsksForIt() {
        let (centre, delivered) = makeCentre()
        XCTAssertFalse(centre.isEnabled, "an app that demands permission on first launch has not earned it")
        XCTAssertFalse(centre.wantsAlert(of: .protectionTripped))

        centre.isEnabled = true
        XCTAssertTrue(centre.wantsAlert(of: .protectionTripped))
        XCTAssertEqual(centre.authorization, .granted, "turning it on is what asks")

        centre.present(PSUAlert(kind: .protectionTripped, title: "OV Tripped", body: "HP6632B shut its output down"))
        XCTAssertEqual(delivered().count, 1)
        XCTAssertEqual(centre.lastPosted?.kind, .protectionTripped)
    }

    func testEachKindCanBeTurnedOffOnItsOwn() {
        let (centre, _) = makeCentre()
        centre.isEnabled = true
        centre.kinds = [.connectionLost]

        XCTAssertTrue(centre.wantsAlert(of: .connectionLost))
        XCTAssertFalse(centre.wantsAlert(of: .protectionTripped))
        XCTAssertFalse(centre.wantsAlert(of: .wentToConstantCurrent))
    }

    func testABannerOverTheWindowThatAlreadySaysItIsSuppressed() {
        let (foreground, _) = makeCentre(appIsActive: true)
        foreground.isEnabled = true
        XCTAssertFalse(foreground.wantsAlert(of: .protectionTripped), "the panel is right there")

        foreground.onlyWhenInBackground = false
        XCTAssertTrue(foreground.wantsAlert(of: .protectionTripped), "unless it was asked for anyway")
    }

    func testTheBannerHistoryIsBounded() {
        let (centre, _) = makeCentre()
        centre.isEnabled = true
        for index in 0..<40 {
            centre.present(PSUAlert(kind: .wentToConstantCurrent, title: "CC", body: "\(index)"))
        }
        XCTAssertEqual(centre.posted.count, 20)
        XCTAssertEqual(centre.lastPosted?.body, "39")
    }

    func testAlertSettingsSurviveARestart() {
        let store = PreferenceStore.ephemeral()

        let first = AppModel(store: store)
        first.alerts.kinds = [.wentToConstantCurrent]
        first.alerts.onlyWhenInBackground = false
        first.showsMenuBarReading = false
        first.saveNow()

        let second = AppModel(store: store)
        XCTAssertEqual(second.alerts.kinds, [.wentToConstantCurrent])
        XCTAssertFalse(second.alerts.onlyWhenInBackground)
        XCTAssertFalse(second.showsMenuBarReading)
        XCTAssertFalse(second.alerts.isEnabled, "and permission is not re-requested for a switch that was off")
    }

    func testTheModelHandsItsAlertsToTheController() {
        let model = AppModel(store: .ephemeral())
        XCTAssertTrue(model.controller.alerts === model.alerts)
    }

    // MARK: - Menu bar

    func testTheMenuBarSaysNothingRatherThanZeroWhenThereIsNoSupply() {
        let controller = PSUController()
        let readout = MenuBarReadout(controller: controller)
        readout.sample()

        XCTAssertFalse(readout.isConnected)
        XCTAssertEqual(readout.title, "—")
    }

    func testTheMenuBarItemAlwaysHasSomethingToShow() {
        // The item is drawn from `title` alone, so an empty one would leave a
        // bare icon in the bar with nothing to say whose it is.
        let controller = PSUController()
        let readout = MenuBarReadout(controller: controller)
        for _ in 0..<3 {
            readout.sample()
            XCTAssertFalse(readout.title.isEmpty)
        }
        XCTAssertFalse(MenuBarReadout.compactReading(of: controller).isEmpty)
    }

    /// Milliamps to three decimals is right in front of a 58-point readout and
    /// three digits too many beside the clock.
    func testTheMenuBarReadingStaysNarrowEnoughForAMenuBar() {
        let controller = PSUController()
        XCTAssertLessThanOrEqual(MenuBarReadout.compactReading(of: controller).count, 16)
    }

    func testTheMenuBarUpdatesSlowlyEnoughToBeRead() {
        XCTAssertGreaterThanOrEqual(MenuBarReadout.updateInterval, 0.25)
        XCTAssertLessThanOrEqual(MenuBarReadout.updateInterval, 1.0)
    }

    // MARK: - Shortcuts vocabulary

    func testEveryValueShortcutsOffersHasANameAndAUnit() {
        for choice in MeasurementChoice.allCases {
            XCTAssertNotNil(MeasurementChoice.caseDisplayRepresentations[choice],
                            "\(choice) has no name for Shortcuts to show")
            XCTAssertFalse(choice.unit.isEmpty)
            XCTAssertFalse(choice.title.isEmpty)
        }
        XCTAssertEqual(MeasurementChoice.voltage.unit, "V")
        XCTAssertEqual(MeasurementChoice.current.unit, "A")
        XCTAssertEqual(MeasurementChoice.power.unit, "W")
    }

    /// Nothing measured yet is nil, not zero dressed up as an answer: a shortcut
    /// logging a column of zeroes because the first pass had not landed is worse
    /// than one that stops and says so.
    func testAValueThatHasNotBeenMeasuredIsNotInvented() {
        let controller = PSUController()
        for choice in MeasurementChoice.allCases {
            XCTAssertNil(choice.value(from: controller), "\(choice) invented a value")
        }
    }

    func testBothOutputStatesHaveAName() {
        for state in OutputSwitch.allCases {
            XCTAssertNotNil(OutputSwitch.caseDisplayRepresentations[state])
        }
    }

    func testAnIntentWithNoApplicationBehindItSaysSo() async {
        let previous = AppModel.current
        AppModel.current = nil
        defer { AppModel.current = previous }

        do {
            _ = try await ReadSupplyIntent().perform()
            XCTFail("an intent cannot read a supply that nothing is holding open")
        } catch let error as IntentError {
            XCTAssertEqual(error, .notRunning)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAnIntentWithNoSupplyConnectedSaysThatInstead() async {
        let previous = AppModel.current
        AppModel.current = AppModel(store: .ephemeral())
        defer { AppModel.current = previous }

        do {
            _ = try await SetSupplyOutputIntent().perform()
            XCTFail("there is no supply to switch")
        } catch let error as IntentError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}


/// The intents against a supply that is actually answering — the only way to
/// see that a shortcut moves the output rather than merely returning a dialog.
@MainActor
final class IntentIntegrationTests: XCTestCase {

    private var server: SimulatorServer!
    private var model: AppModel!
    private var previous: AppModel?

    override func setUp() async throws {
        server = try SimulatorServer()
        server.start()
        server.simulatedDevice.loadResistance = 100

        model = AppModel(store: .ephemeral())
        model.controller.beeperEnabled = false
        model.controller.updateRate = 0.05

        let config = SerialConfig(path: server.devicePath, readTimeout: 2, writeTimeout: 2)
        let identity = try ConnectionProbe.identify(config: config)
        model.controller.connect(config: config, identity: identity)

        previous = AppModel.current
        AppModel.current = model
    }

    override func tearDown() async throws {
        AppModel.current = previous
        model?.controller.disconnect()
        server?.stop()
        model = nil
        server = nil
    }

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

    /// The shortcut a bench actually wants: set a voltage, wait, read the
    /// current back. Do that in a loop and you have an I-V curve.
    func testAShortcutCanSetTheOutputAndReadItBack() async throws {
        var intent = SetSupplyVoltageIntent()
        intent.volts = 4.19
        _ = try await intent.perform()

        // The supply comes up with its current limit at zero, so a shortcut that
        // only set a voltage would sit in constant current at nothing.
        var limit = SetSupplyCurrentIntent()
        limit.amps = 1
        _ = try await limit.perform()

        var output = SetSupplyOutputIntent()
        output.state = .on
        _ = try await output.perform()

        try await eventually("the supply to regulate") { self.model.controller.outputMode == .constantVoltage }

        var read = ReadSupplyIntent()
        read.measurement = .voltage
        let voltage = try await read.perform().value
        XCTAssertEqual(try XCTUnwrap(voltage), 4.19, accuracy: 0.05)

        read.measurement = .current
        let current = try await read.perform().value
        XCTAssertEqual(try XCTUnwrap(current), 0.0419, accuracy: 0.005, "4.19 V into 100 Ω")

        output.state = .off
        _ = try await output.perform()
        try await eventually("the output to go off") { !self.model.controller.isOutputEnabled }
    }

    func testAVoltageBeyondTheSupplyRatingIsRefusedRatherThanSent() async throws {
        var intent = SetSupplyVoltageIntent()
        intent.volts = 500

        do {
            _ = try await intent.perform()
            XCTFail("a 6632B does not do 500 V")
        } catch let error as IntentError {
            guard case .beyondRating(let explanation) = error else {
                return XCTFail("wrong refusal: \(error)")
            }
            XCTAssertTrue(explanation.contains("500"), "the refusal says what was asked for")
        }

        // And nothing went down the wire.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotEqual(model.controller.setVoltageReadback, 500)
    }

    func testResettingTheHistoryFromAShortcutEmptiesTheGraphs() async throws {
        var output = SetSupplyOutputIntent()
        output.state = .on
        _ = try await output.perform()
        try await eventually("samples") { self.model.controller.voltageHistory.samples.count > 2 }

        _ = try await ResetHistoryIntent().perform()
        XCTAssertTrue(model.controller.voltageHistory.isEmpty)
    }
}
