import Foundation

/// The SCPI command set used by the HP/Agilent/Keysight 663x2A, 663xB and 661xC
/// System DC power supplies. Command spelling matches the Windows original so
/// behaviour against real hardware is identical.
public enum SCPI {
    public static let selectSCPILanguage = "SYST:LANG SCPI"
    public static let identify = "*IDN?"
    public static let reset = "*RST"

    public static let maxVoltageQuery = "VOLT? MAX"
    public static let maxCurrentQuery = "CURR? MAX"
    public static let maxOVPQuery = "VOLT:PROT:LEV? MAX"

    public static let measureVoltage = "MEAS:VOLT?"
    public static let measureCurrent = "MEAS:CURR?"

    public static let setVoltageQuery = "VOLT:LEV?"
    public static let setCurrentQuery = "CURR:LEV?"

    public static let operationCondition = "STAT:OPER:COND?"
    public static let questionableCondition = "STAT:QUES:COND?"
    public static let errorQuery = "SYST:ERR?"

    public static let outputOn = "OUTPut ON"
    public static let outputOff = "OUTPut OFF"
    public static let clearProtection = "OUTP:PROT:CLE"

    public static let ocpEnable = "CURR:PROT:STAT 1"
    public static let ocpDisable = "CURR:PROT:STAT 0"
    public static let ocpStateQuery = "CURR:PROT:STAT?"
    public static let ovpQuery = "VOLT:PROT:LEV?"

    public static let currentRangeHigh = "SENSe:CURRent:RANGe MAX"
    public static let currentRangeLow = "SENSe:CURRent:RANGe MIN"

    public static let displayOn = "DISP ON"
    public static let displayOff = "DISP OFF"
    public static let displayModeNormal = "DISPLAY:MODE NORM"
    public static let displayModeText = "DISPLAY:MODE TEXT"

    public static func setVoltage(_ volts: Double) -> String { "VOLT \(format(volts))" }
    public static func setCurrent(_ amps: Double) -> String { "CURR \(format(amps))" }
    public static func setOVP(_ volts: Double) -> String { "VOLT:PROT \(format(volts))" }

    /// The front panel accepts a quoted string of up to 12 characters.
    public static func displayText(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "'", with: " ")
        return "DISP:TEXT '\(String(cleaned.prefix(12)))'"
    }

    /// Fixed-notation, period-decimal formatting. The device rejects the comma
    /// decimal separator some locales would otherwise produce.
    public static func format(_ value: Double) -> String {
        String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

public enum SCPIParse {
    /// Value the supply returns instead of a reading when the measurement is out
    /// of range on the selected current range (`9.91000E+37`).
    public static let overloadSentinel = 9.9e37

    /// Parses a SCPI numeric response such as `+4.19000E+00`.
    /// Returns nil for anything that is not a finite number.
    public static func number(_ response: String?) -> Double? {
        guard let response else { return nil }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// True when the response is the out-of-range sentinel rather than a reading.
    public static func isOverload(_ value: Double) -> Bool {
        abs(value) >= overloadSentinel
    }

    public static func integer(_ response: String?) -> Int? {
        guard let value = number(response) else { return nil }
        return Int(value.rounded())
    }
}

/// Decoded `STAT:OPER:COND?` register — how the output is regulating.
public enum OutputMode: Equatable, Sendable {
    case disabled
    case constantVoltage
    case constantCurrent
    case constantVoltageAndCurrent
    case negativeConstantCurrent
    case unknown(Int)

    /// Bit 8 = CV, bit 10 = CC (sourcing), bit 11 = CC (sinking).
    public static func decode(_ condition: Int) -> OutputMode {
        let cv = condition & 256 != 0
        let cc = condition & 1024 != 0
        let negativeCC = condition & 2048 != 0

        switch (cv, cc, negativeCC) {
        case (false, false, false) where condition == 0: return .disabled
        case (true, true, _): return .constantVoltageAndCurrent
        case (true, false, _): return .constantVoltage
        case (false, true, _): return .constantCurrent
        case (false, false, true): return .negativeConstantCurrent
        default: return .unknown(condition)
        }
    }

    /// Short label for the big status readout, as on the Windows panel.
    public var label: String {
        switch self {
        case .disabled: return "Dis"
        case .constantVoltage: return "CV"
        case .constantCurrent: return "CC"
        case .constantVoltageAndCurrent: return "CVCC"
        case .negativeConstantCurrent: return "-CC"
        case .unknown: return "?"
        }
    }

    public var isOutputEnabled: Bool {
        switch self {
        case .disabled: return false
        case .unknown: return false
        default: return true
        }
    }

    /// The output is being held by the current limit rather than the voltage
    /// setting. CVCC counts: the supply reports both bits at the crossover, and
    /// the crossover is the moment worth knowing about.
    public var isCurrentLimited: Bool {
        switch self {
        case .constantCurrent, .negativeConstantCurrent, .constantVoltageAndCurrent: return true
        default: return false
        }
    }
}

/// Decoded `STAT:QUES:COND?` register — which protection has tripped.
public struct ProtectionStatus: Equatable, Sendable {
    public let condition: Int

    public init(condition: Int) {
        self.condition = condition
    }

    public var isClear: Bool { condition == 0 }

    /// Bit 0 OV, bit 1 OCP, bit 2 FS (fuse/sense fault), bit 4 OT, bit 9 unregulated.
    public var trippedLabels: [String] {
        var labels: [String] = []
        if condition & 1 != 0 { labels.append("OV Tripped") }
        if condition & 2 != 0 { labels.append("OCP Tripped") }
        if condition & 4 != 0 { labels.append("FS Tripped") }
        if condition & 16 != 0 { labels.append("OT Tripped") }
        if condition & 512 != 0 { labels.append("Unregulated") }

        if labels.isEmpty && condition != 0 {
            labels.append("Fault (\(condition))")
        }
        return labels
    }
}

/// What `*IDN?` and the MAX queries told us about the connected supply.
public struct DeviceIdentity: Equatable, Sendable {
    public let rawIdentification: String
    public let model: String
    public let maxVoltage: Double
    public let maxCurrent: Double
    public let maxOVP: Double

    public init(rawIdentification: String, model: String, maxVoltage: Double, maxCurrent: Double, maxOVP: Double) {
        self.rawIdentification = rawIdentification
        self.model = model
        self.maxVoltage = maxVoltage
        self.maxCurrent = maxCurrent
        self.maxOVP = maxOVP
    }

    /// `HEWLETT-PACKARD,6632B,0,A.01.04` becomes `HP6632B`, matching the
    /// window title and log file names the Windows version produced.
    public static func shortModel(from identification: String) -> String {
        let fields = identification.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return identification.trimmingCharacters(in: .whitespaces) }
        let model = fields[1].trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? identification : "HP" + model
    }
}
