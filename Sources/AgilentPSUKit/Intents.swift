import AppIntents
import Foundation
import PSUCore

/// Shortcuts and the automation tools that sit on top of App Intents.
///
/// The point is not to run a bench supply from an iPhone. It is that the supply
/// becomes something a script can drive and question: step the voltage, wait,
/// read the current, write the pair into a spreadsheet — an I-V curve taken by
/// a shortcut rather than by hand. The Windows original has nothing of the sort,
/// and neither has the supply: its own interface is this serial line and the
/// front panel.
///
/// Every intent works on the running application: the serial port is open in
/// this process and cannot be shared. `openAppWhenRun` is therefore not
/// optional — an intent that arrived while the app was closed would otherwise
/// have nothing to talk to.

// MARK: - Reading

struct ReadSupplyIntent: AppIntent {
    static let title: LocalizedStringResource = "Read the Supply"
    static let description = IntentDescription(
        "Returns a measured or set value from the supply — volts, amps or watts.",
        categoryName: "Measurement"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Value", default: .voltage)
    var measurement: MeasurementChoice

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let controller = try IntentSupport.connectedController()
        guard let value = measurement.value(from: controller) else {
            throw IntentError.nothingMeasuredYet
        }
        let text = Format.number(value, measurement.digits) + measurement.unit
        return .result(value: value, dialog: IntentDialog(stringLiteral: "\(measurement.title): \(text)"))
    }
}

enum MeasurementChoice: String, AppEnum, CaseIterable {
    case voltage, current, power, setVoltage, setCurrent

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Value")

    static let caseDisplayRepresentations: [MeasurementChoice: DisplayRepresentation] = [
        .voltage: "Measured Voltage",
        .current: "Measured Current",
        .power: "Calculated Power",
        .setVoltage: "Voltage Set Point",
        .setCurrent: "Current Set Point",
    ]

    var title: String {
        switch self {
        case .voltage: return "Measured voltage"
        case .current: return "Measured current"
        case .power: return "Power"
        case .setVoltage: return "Voltage set point"
        case .setCurrent: return "Current set point"
        }
    }

    var unit: String {
        switch self {
        case .voltage, .setVoltage: return "V"
        case .current, .setCurrent: return "A"
        case .power: return "W"
        }
    }

    var digits: Int {
        switch self {
        case .voltage, .setVoltage, .power: return 3
        case .current, .setCurrent: return 4
        }
    }

    /// Nil rather than zero when the supply has not answered yet: a shortcut
    /// that logs a column of zeroes because the first pass had not landed is
    /// worse than one that stops and says so.
    @MainActor
    func value(from controller: PSUController) -> Double? {
        switch self {
        case .voltage: return controller.voltageIsValid ? controller.measuredVoltage : nil
        case .current: return controller.currentIsValid ? controller.measuredCurrent : nil
        case .power: return (controller.voltageIsValid && controller.currentIsValid) ? controller.measuredPower : nil
        case .setVoltage: return controller.setVoltageReadback
        case .setCurrent: return controller.setCurrentReadback
        }
    }
}

// MARK: - Control

struct SetSupplyVoltageIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Output Voltage"
    static let description = IntentDescription(
        "Sets the supply's voltage set point, in volts. Stepping this in a loop is what makes an I-V sweep.",
        categoryName: "Control"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Volts")
    var volts: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try IntentSupport.connectedController()
        let limit = controller.identity?.maxVoltage ?? 0
        guard volts >= 0, volts <= limit else {
            throw IntentError.beyondRating("\(Format.number(volts, 3))V is outside what this supply can do — 0 to \(Format.number(limit, 2))V.")
        }
        controller.setVoltage(volts, inMillivolts: false)
        return .result(dialog: IntentDialog(stringLiteral: "Set to \(Format.number(volts, 3))V."))
    }
}

struct SetSupplyCurrentIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Current Limit"
    static let description = IntentDescription(
        "Sets the supply's current limit, in amps. Reaching it is what puts the output into constant current.",
        categoryName: "Control"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Amps")
    var amps: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try IntentSupport.connectedController()
        let limit = controller.identity?.maxCurrent ?? 0
        guard amps >= 0, amps <= limit else {
            throw IntentError.beyondRating("\(Format.number(amps, 4))A is outside what this supply can do — 0 to \(Format.number(limit, 3))A.")
        }
        controller.setCurrent(amps, inMilliamps: false)
        return .result(dialog: IntentDialog(stringLiteral: "Limit set to \(Format.number(amps, 4))A."))
    }
}

struct SetSupplyOutputIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch the Output"
    static let description = IntentDescription(
        "Turns the supply's output on or off. On means volts across whatever is wired up — worth knowing before a shortcut does it unattended.",
        categoryName: "Control"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Output", default: .off)
    var state: OutputSwitch

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try IntentSupport.connectedController()
        controller.setOutput(enabled: state == .on)
        return .result(dialog: IntentDialog(stringLiteral: "Output \(state.rawValue)."))
    }
}

enum OutputSwitch: String, AppEnum, CaseIterable {
    case on, off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Output State")

    static let caseDisplayRepresentations: [OutputSwitch: DisplayRepresentation] = [
        .on: "On",
        .off: "Off",
    ]
}

struct ClearProtectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Protection"
    static let description = IntentDescription(
        "Clears a protection trip once the cause is gone, so the output can be turned on again.",
        categoryName: "Control"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try IntentSupport.connectedController()
        controller.clearProtection()
        return .result(dialog: "Protection cleared.")
    }
}

struct ResetHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset History and Counters"
    static let description = IntentDescription(
        "Throws away the graph histories and the sample counters — what you want at the top of a run.",
        categoryName: "Control"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try IntentSupport.connectedController()
        controller.resetHistory()
        return .result(dialog: "History cleared.")
    }
}

// MARK: - Spoken phrases

struct AgilentPSUShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReadSupplyIntent(),
            phrases: [
                "Read the supply with \(.applicationName)",
                "What is \(.applicationName) putting out",
            ],
            shortTitle: "Read the Supply",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: SetSupplyVoltageIntent(),
            phrases: ["Set the \(.applicationName) voltage"],
            shortTitle: "Set Output Voltage",
            systemImageName: "slider.horizontal.3"
        )
        AppShortcut(
            intent: SetSupplyOutputIntent(),
            phrases: ["Switch the \(.applicationName) output"],
            shortTitle: "Switch the Output",
            systemImageName: "power"
        )
        AppShortcut(
            intent: ResetHistoryIntent(),
            phrases: ["Reset \(.applicationName)"],
            shortTitle: "Reset History",
            systemImageName: "arrow.counterclockwise"
        )
    }
}

// MARK: - Shared plumbing

enum IntentSupport {
    /// The controller of the running application, or a refusal that says which
    /// of the two things is missing — the app or the supply.
    @MainActor
    static func connectedController() throws -> PSUController {
        guard let model = AppModel.current else { throw IntentError.notRunning }
        guard model.controller.isConnected else { throw IntentError.notConnected }
        return model.controller
    }
}

enum IntentError: Swift.Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notRunning
    case notConnected
    case nothingMeasuredYet
    case beyondRating(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning:
            return "The power supply application is not running yet."
        case .notConnected:
            return "No supply is connected. Open the app and choose a serial port first."
        case .nothingMeasuredYet:
            return "The supply has not reported that value yet — it may not be in the polling plan."
        case .beyondRating(let explanation):
            return LocalizedStringResource(stringLiteral: explanation)
        }
    }
}
