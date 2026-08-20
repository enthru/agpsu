import XCTest
@testable import PSUCore

final class ProtocolTests: XCTestCase {

    func testParsesSCPINumericResponses() {
        XCTAssertEqual(SCPIParse.number("+4.19000E+00"), 4.19)
        XCTAssertEqual(SCPIParse.number(" -1.50000E-02 "), -0.015)
        XCTAssertEqual(SCPIParse.number("20.475"), 20.475)
        XCTAssertNil(SCPIParse.number("Null"))
        XCTAssertNil(SCPIParse.number(""))
        XCTAssertNil(SCPIParse.number(nil))
    }

    func testDetectsCurrentOverloadSentinel() {
        let value = SCPIParse.number("+9.91000E+37")
        XCTAssertNotNil(value)
        XCTAssertTrue(SCPIParse.isOverload(value!))
        XCTAssertFalse(SCPIParse.isOverload(5.0))
    }

    func testDecodesOperationConditionRegister() {
        XCTAssertEqual(OutputMode.decode(0), .disabled)
        XCTAssertEqual(OutputMode.decode(256), .constantVoltage)
        XCTAssertEqual(OutputMode.decode(1024), .constantCurrent)
        XCTAssertEqual(OutputMode.decode(1280), .constantVoltageAndCurrent)
        XCTAssertEqual(OutputMode.decode(2048), .negativeConstantCurrent)
        XCTAssertEqual(OutputMode.decode(256).label, "CV")
        XCTAssertEqual(OutputMode.decode(1280).label, "CVCC")
        XCTAssertFalse(OutputMode.decode(0).isOutputEnabled)
        XCTAssertTrue(OutputMode.decode(1024).isOutputEnabled)
    }

    func testDecodesQuestionableConditionRegister() {
        XCTAssertTrue(ProtectionStatus(condition: 0).isClear)
        XCTAssertEqual(ProtectionStatus(condition: 1).trippedLabels, ["OV Tripped"])
        XCTAssertEqual(ProtectionStatus(condition: 2).trippedLabels, ["OCP Tripped"])
        XCTAssertEqual(ProtectionStatus(condition: 16).trippedLabels, ["OT Tripped"])
        // Combined trips are reported individually rather than falling through
        // to the "unknown value" case the Windows switch statement produced.
        XCTAssertEqual(ProtectionStatus(condition: 3).trippedLabels, ["OV Tripped", "OCP Tripped"])
    }

    func testShortModelMatchesWindowsNaming() {
        XCTAssertEqual(DeviceIdentity.shortModel(from: "HEWLETT-PACKARD,6632B,0,A.01.04"), "HP6632B")
        XCTAssertEqual(DeviceIdentity.shortModel(from: "Agilent Technologies,66332A,0,A.03.01"), "HP66332A")
    }

    func testCommandFormattingUsesPeriodDecimalSeparator() {
        XCTAssertEqual(SCPI.setVoltage(4.19), "VOLT 4.19")
        XCTAssertEqual(SCPI.setCurrent(0.3), "CURR 0.3")
        XCTAssertEqual(SCPI.setOVP(4.3), "VOLT:PROT 4.3")
        XCTAssertEqual(SCPI.displayText("Hello World!"), "DISP:TEXT 'Hello World!'")
        XCTAssertEqual(SCPI.displayText("A very long message"), "DISP:TEXT 'A very long '", "the front panel takes 12 characters")
    }

    func testDisplayAutoRangingMatchesPanelBehaviour() {
        let auto = DisplayRange(isAuto: true, threshold: 1.0)
        XCTAssertEqual(Format.voltage(0.005, range: auto), "5mV")
        XCTAssertEqual(Format.voltage(4.19, range: auto), "4.190V")
        XCTAssertEqual(Format.current(0.075429, range: auto), "75.429mA")
        XCTAssertEqual(Format.power(0.316, range: auto), "316.0mW")

        let fixed = DisplayRange(isAuto: false, threshold: 1.0)
        XCTAssertEqual(Format.voltage(0.005, range: fixed), "0.005V")
    }

    func testRuntimeFormatting() {
        XCTAssertEqual(Format.duration(1220), "00:20:20")
        XCTAssertEqual(Format.duration(3661), "01:01:01")
    }
}
