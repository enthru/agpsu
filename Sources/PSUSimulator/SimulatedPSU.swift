import Foundation

/// A SCPI-speaking stand-in for a 663x/661x supply.
///
/// It models enough of the instrument to exercise the whole application: the
/// CV/CC crossover against a resistive load, OVP and OCP trips, the operation
/// and questionable status registers, the error queue and the front panel
/// display. Responses use the same `+4.19000E+00` notation as the real supplies.
public final class SimulatedPSU {

    public struct Model: Sendable {
        public var identification: String
        public var maxVoltage: Double
        public var maxCurrent: Double
        public var maxOVP: Double
        /// Threshold below which the low current range is accurate.
        public var lowCurrentRangeLimit: Double

        public static let hp6632B = Model(
            identification: "HEWLETT-PACKARD,6632B,0,A.01.04",
            maxVoltage: 20.475,
            maxCurrent: 5.1188,
            maxOVP: 22.0,
            lowCurrentRangeLimit: 0.02
        )
    }

    public let model: Model

    /// Resistance of the simulated load in ohms. Drives the CV/CC crossover:
    /// with 10 Ω, 5 V and a 0.3 A limit the supply lands in constant current.
    public var loadResistance: Double = 10.0
    /// Peak-to-peak measurement noise, as a fraction of the reading.
    public var noiseFraction: Double = 0.0005

    private(set) var setVoltage: Double = 0
    private(set) var setCurrent: Double = 0
    private(set) var ovpLevel: Double
    private(set) var ocpEnabled = false
    private(set) var outputOn = false
    private(set) var questionable: Int = 0
    private(set) var lowCurrentRange = false

    public private(set) var displayOn = true
    public private(set) var displayText: String?
    public private(set) var displayMode = "NORM"

    private var errorQueue: [String] = []
    private var noiseState: UInt64 = 0x2545F4914F6CDD1D

    public init(model: Model = .hp6632B) {
        self.model = model
        self.ovpLevel = model.maxOVP
    }

    // MARK: - Electrical model

    /// Operating point given the current settings and the simulated load.
    private var operatingPoint: (voltage: Double, current: Double, mode: Mode) {
        guard outputOn, questionable == 0 else { return (0, 0, .off) }

        let openCircuitCurrent = loadResistance > 0 ? setVoltage / loadResistance : .infinity
        if openCircuitCurrent <= setCurrent {
            return (setVoltage, openCircuitCurrent, .constantVoltage)
        }
        // Current limited: the supply backs the voltage off to hold `setCurrent`.
        return (setCurrent * loadResistance, setCurrent, .constantCurrent)
    }

    private enum Mode {
        case off, constantVoltage, constantCurrent
    }

    /// Deterministic pseudo-noise — no `Double.random` so runs are reproducible.
    private func noise() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 7
        noiseState ^= noiseState << 17
        let unit = Double(noiseState % 10_000) / 10_000.0
        return (unit - 0.5) * 2 * noiseFraction
    }

    /// Applies protection rules; called before every measurement or status read.
    private func evaluateProtection() {
        guard outputOn, questionable == 0 else { return }
        let point = operatingPoint

        if point.voltage > ovpLevel {
            questionable |= 1        // OV
            outputOn = false
            pushError("-410,\"Query INTERRUPTED\"")
            return
        }
        if ocpEnabled && point.mode == .constantCurrent {
            questionable |= 2        // OCP
            outputOn = false
        }
    }

    private func pushError(_ text: String) {
        if errorQueue.count < 16 { errorQueue.append(text) }
    }

    // MARK: - SCPI

    /// Handles one command line. Returns the response, or nil for commands that
    /// do not produce one.
    public func respond(to line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Take the argument from the first space; keep quoted text intact.
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        var header = String(parts[0]).uppercased()
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        let isQuery = header.hasSuffix("?")
        if isQuery { header.removeLast() }
        let canonical = Self.canonical(header)

        switch (canonical, isQuery) {
        case ("*IDN", true):
            return model.identification
        case ("*RST", false):
            reset()
            return nil
        case ("*CLS", false):
            questionable = 0
            errorQueue.removeAll()
            return nil

        case ("SYST:LANG", false):
            return nil
        case ("SYST:ERR", true):
            return errorQueue.isEmpty ? "+0,\"No error\"" : errorQueue.removeFirst()

        case ("VOLT", true):
            return number(argument.uppercased().hasPrefix("MAX") ? model.maxVoltage : setVoltage)
        case ("VOLT", false):
            setVoltage = clamp(value(argument), 0, model.maxVoltage)
            evaluateProtection()
            return nil
        case ("VOLT:LEV", true):
            return number(argument.uppercased().hasPrefix("MAX") ? model.maxVoltage : setVoltage)
        case ("VOLT:LEV", false):
            setVoltage = clamp(value(argument), 0, model.maxVoltage)
            evaluateProtection()
            return nil

        case ("CURR", true):
            return number(argument.uppercased().hasPrefix("MAX") ? model.maxCurrent : setCurrent)
        case ("CURR", false):
            setCurrent = clamp(value(argument), 0, model.maxCurrent)
            evaluateProtection()
            return nil
        case ("CURR:LEV", true):
            return number(argument.uppercased().hasPrefix("MAX") ? model.maxCurrent : setCurrent)
        case ("CURR:LEV", false):
            setCurrent = clamp(value(argument), 0, model.maxCurrent)
            return nil

        case ("VOLT:PROT", false), ("VOLT:PROT:LEV", false):
            let requested = value(argument)
            guard requested <= model.maxOVP else {
                pushError("-222,\"Data out of range\"")
                return nil
            }
            ovpLevel = requested
            evaluateProtection()
            return nil
        case ("VOLT:PROT", true), ("VOLT:PROT:LEV", true):
            return number(argument.uppercased().hasPrefix("MAX") ? model.maxOVP : ovpLevel)

        case ("CURR:PROT:STAT", false):
            ocpEnabled = booleanValue(argument)
            evaluateProtection()
            return nil
        case ("CURR:PROT:STAT", true):
            return ocpEnabled ? "1" : "0"

        case ("MEAS:VOLT", true):
            evaluateProtection()
            let point = operatingPoint
            return number(point.voltage * (1 + noise()))
        case ("MEAS:CURR", true):
            evaluateProtection()
            let point = operatingPoint
            if lowCurrentRange && point.current > model.lowCurrentRangeLimit {
                return number(9.91e37)   // over range for the selected shunt
            }
            return number(point.current * (1 + noise()))

        case ("OUTP", false):
            let turningOn = booleanValue(argument)
            if turningOn && questionable != 0 {
                pushError("-221,\"Settings conflict\"")
            } else {
                outputOn = turningOn
                evaluateProtection()
            }
            return nil
        case ("OUTP", true):
            return outputOn ? "1" : "0"
        case ("OUTP:PROT:CLE", false):
            questionable = 0
            return nil

        case ("STAT:OPER:COND", true):
            evaluateProtection()
            switch operatingPoint.mode {
            case .off: return "+0"
            case .constantVoltage: return "+256"
            case .constantCurrent: return "+1024"
            }
        case ("STAT:QUES:COND", true):
            evaluateProtection()
            return "+\(questionable)"

        case ("SENS:CURR:RANG", false):
            lowCurrentRange = argument.uppercased().hasPrefix("MIN") || (value(argument) <= model.lowCurrentRangeLimit)
            return nil
        case ("SENS:CURR:RANG", true):
            return number(lowCurrentRange ? model.lowCurrentRangeLimit : model.maxCurrent)

        case ("DISP", false):
            displayOn = booleanValue(argument)
            return nil
        case ("DISP:MODE", false):
            displayMode = argument.uppercased()
            return nil
        case ("DISP:TEXT", false):
            displayText = argument.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            return nil

        default:
            pushError("-113,\"Undefined header\"")
            return isQuery ? "+0" : nil
        }
    }

    public func reset() {
        setVoltage = 0
        setCurrent = 0
        outputOn = false
        ocpEnabled = false
        ovpLevel = model.maxOVP
        questionable = 0
        lowCurrentRange = false
        displayMode = "NORM"
        displayText = nil
        errorQueue.removeAll()
    }

    // MARK: - Helpers

    private func number(_ value: Double) -> String {
        String(format: "%+.5E", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func value(_ text: String) -> Double {
        let upper = text.uppercased()
        if upper.hasPrefix("MAX") { return .greatestFiniteMagnitude }
        if upper.hasPrefix("MIN") { return 0 }
        return Double(text) ?? 0
    }

    private func booleanValue(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper == "ON" || upper == "1" || upper == "TRUE"
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }

    /// Expands SCPI short-form mnemonics so `MEAS:VOLT?` and `MEASURE:VOLTAGE?`
    /// reach the same branch.
    static func canonical(_ header: String) -> String {
        let expansions: [String: String] = [
            "VOLTAGE": "VOLT", "CURRENT": "CURR", "MEASURE": "MEAS",
            "OUTPUT": "OUTP", "PROTECTION": "PROT", "LEVEL": "LEV",
            "STATUS": "STAT", "OPERATION": "OPER", "QUESTIONABLE": "QUES",
            "CONDITION": "COND", "SYSTEM": "SYST", "ERROR": "ERR",
            "DISPLAY": "DISP", "SENSE": "SENS", "RANGE": "RANG",
            "LANGUAGE": "LANG", "STATE": "STAT", "CLEAR": "CLE",
        ]
        return header
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { expansions[String($0)] ?? String($0) }
            .joined(separator: ":")
    }
}
