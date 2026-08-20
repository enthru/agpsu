import XCTest
@testable import PSUCore
@testable import PSUSimulator

/// End-to-end coverage: a real `termios` serial connection over a pseudo-terminal
/// to the SCPI simulator. Everything except the physical UART is exercised.
final class SimulatorIntegrationTests: XCTestCase {

    private var server: SimulatorServer!
    private var device: PSUDevice!

    override func setUpWithError() throws {
        server = try SimulatorServer()
        server.start()

        device = PSUDevice(config: SerialConfig(path: server.devicePath, readTimeout: 3, writeTimeout: 3))
        try device.open()
    }

    override func tearDown() {
        device?.close()
        server?.stop()
        device = nil
        server = nil
    }

    func testIdentifiesTheSupply() throws {
        let identity = try device.identify()
        XCTAssertEqual(identity.model, "HP6632B")
        XCTAssertEqual(identity.maxVoltage, 20.475, accuracy: 0.001)
        XCTAssertEqual(identity.maxCurrent, 5.1188, accuracy: 0.001)
        XCTAssertEqual(identity.maxOVP, 22.0, accuracy: 0.001)
    }

    func testSetPointsAreReadBack() throws {
        _ = try device.identify()
        try device.send(SCPI.setVoltage(4.19))
        try device.send(SCPI.setCurrent(0.3))

        XCTAssertEqual(device.queryNumber(SCPI.setVoltageQuery)!, 4.19, accuracy: 0.0001)
        XCTAssertEqual(device.queryNumber(SCPI.setCurrentQuery)!, 0.3, accuracy: 0.0001)
    }

    func testConstantVoltageOperatingPoint() throws {
        _ = try device.identify()
        server.simulatedDevice.loadResistance = 100      // 5 V / 100 ohm = 50 mA
        try device.send(SCPI.setVoltage(5))
        try device.send(SCPI.setCurrent(1))
        try device.send(SCPI.outputOn)

        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.operationCondition)), 256)
        XCTAssertEqual(device.queryNumber(SCPI.measureVoltage)!, 5.0, accuracy: 0.01)
        XCTAssertEqual(device.queryNumber(SCPI.measureCurrent)!, 0.05, accuracy: 0.001)
    }

    func testConstantCurrentCrossover() throws {
        _ = try device.identify()
        server.simulatedDevice.loadResistance = 10       // 5 V would draw 500 mA
        try device.send(SCPI.setVoltage(5))
        try device.send(SCPI.setCurrent(0.1))            // limited to 100 mA
        try device.send(SCPI.outputOn)

        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.operationCondition)), 1024)
        XCTAssertEqual(device.queryNumber(SCPI.measureCurrent)!, 0.1, accuracy: 0.001)
        XCTAssertEqual(device.queryNumber(SCPI.measureVoltage)!, 1.0, accuracy: 0.01, "voltage backs off to hold the current limit")
    }

    func testOverVoltageProtectionTripsAndClears() throws {
        _ = try device.identify()
        try device.send(SCPI.setOVP(3.0))
        try device.send(SCPI.setVoltage(5))
        try device.send(SCPI.setCurrent(1))
        try device.send(SCPI.outputOn)

        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.questionableCondition)), 1, "OV bit set")
        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.operationCondition)), 0, "output shut down")

        try device.send(SCPI.setVoltage(2))
        try device.send(SCPI.clearProtection)
        try device.send(SCPI.outputOn)
        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.questionableCondition)), 0)
        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.operationCondition)), 256)
    }

    func testOverCurrentProtectionTripsInConstantCurrent() throws {
        _ = try device.identify()
        server.simulatedDevice.loadResistance = 10
        try device.send(SCPI.setVoltage(5))
        try device.send(SCPI.setCurrent(0.1))
        try device.send(SCPI.ocpEnable)
        try device.send(SCPI.outputOn)

        XCTAssertEqual(device.query(SCPI.ocpStateQuery), "1")
        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.questionableCondition)), 2, "OCP bit set")
    }

    func testLowCurrentRangeReportsOverload() throws {
        _ = try device.identify()
        server.simulatedDevice.loadResistance = 10
        try device.send(SCPI.setVoltage(5))
        try device.send(SCPI.setCurrent(1))
        try device.send(SCPI.outputOn)
        try device.send(SCPI.currentRangeLow)            // 20 mA shunt, 500 mA flowing

        let reading = device.queryNumber(SCPI.measureCurrent)
        XCTAssertNotNil(reading)
        XCTAssertTrue(SCPIParse.isOverload(reading!))
    }

    func testErrorQueueIsEmptyWhenNothingWentWrong() throws {
        _ = try device.identify()
        XCTAssertEqual(device.query(SCPI.errorQuery), "+0,\"No error\"")
    }

    func testResetReturnsTheSupplyToItsPowerOnState() throws {
        _ = try device.identify()
        try device.send(SCPI.setVoltage(5))
        try device.send(SCPI.ocpEnable)
        try device.send(SCPI.outputOn)

        try device.send(SCPI.reset)

        XCTAssertEqual(device.queryNumber(SCPI.setVoltageQuery)!, 0, accuracy: 0.0001)
        XCTAssertEqual(device.query(SCPI.ocpStateQuery), "0")
        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.operationCondition)), 0)
    }

    func testFrontPanelTextIsAccepted() throws {
        _ = try device.identify()
        try device.send(SCPI.displayModeText)
        try device.send(SCPI.displayText("Hello World!"))
        // A query round-trips through the simulator's reader thread, so once it
        // answers the preceding write-only commands have certainly been handled.
        _ = device.query(SCPI.errorQuery)
        XCTAssertEqual(server.simulatedDevice.displayText, "Hello World!")
        XCTAssertEqual(server.simulatedDevice.displayMode, "TEXT")
    }

    func testUnknownCommandLandsInTheErrorQueue() throws {
        _ = try device.identify()
        try device.send("NOSUCH:COMMAND 1")
        XCTAssertEqual(device.query(SCPI.errorQuery), "-113,\"Undefined header\"")
    }

    func testReadTimesOutWhenNoAnswerIsComing() throws {
        _ = try device.identify()
        // A set command produces no response, so a bare read must give up rather
        // than block the polling worker forever.
        try device.send(SCPI.setVoltage(1))
        let started = Date()
        XCTAssertNil(device.query("VOLT 1"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
