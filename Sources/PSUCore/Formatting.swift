import Foundation

/// Display auto-ranging: below `threshold` a reading is shown in milli-units.
/// The Windows menus offered Disable / 200m / 400m / 500m / 800m / 1 for each of
/// voltage, current and power; the same choices are kept here.
public struct DisplayRange: Equatable, Sendable, Codable {
    public var isAuto: Bool
    public var threshold: Double

    public static let thresholdChoices: [Double] = [0.2, 0.4, 0.5, 0.8, 1.0]

    public init(isAuto: Bool = true, threshold: Double = 1.0) {
        self.isAuto = isAuto
        self.threshold = threshold
    }

    public func usesMilli(for value: Double) -> Bool {
        isAuto && value > 0 && value < threshold
    }
}

public enum Format {
    /// Half-away-from-zero rounding, matching .NET's `MidpointRounding.AwayFromZero`
    /// so displayed values agree digit for digit with the Windows version.
    public static func round(_ value: Double, _ digits: Int) -> Double {
        let scale = pow(10.0, Double(digits))
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    public static func number(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), round(value, digits))
    }

    public static func voltage(_ value: Double, range: DisplayRange) -> String {
        range.usesMilli(for: value) ? "\(number(value * 1000, 0))mV" : "\(number(value, 3))V"
    }

    public static func current(_ value: Double, range: DisplayRange) -> String {
        range.usesMilli(for: value) ? "\(number(value * 1000, 3))mA" : "\(number(value, 4))A"
    }

    public static func power(_ value: Double, range: DisplayRange) -> String {
        range.usesMilli(for: value) ? "\(number(value * 1000, 1))mW" : "\(number(value, 3))W"
    }

    /// `00:20:20` — the runtime counter in the status bar.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
