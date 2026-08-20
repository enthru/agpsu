import SwiftUI
import Observation
import PSUCore

/// The output as it appears in the menu bar, sampled on a slow timer.
///
/// Not simply read from the controller: a fast polling plan updates several
/// times a second, the width of the item would twitch on every digit, and
/// nothing about a number changing that fast can be read anyway. Two updates a
/// second is as fast as the eye has any use for.
///
/// The timer is also what keeps the observation graph out of it. A view that
/// read the controller directly would be invalidated by every snapshot; this
/// object reads it from a timer callback instead, so only `title` changes and
/// only the menu bar item redraws.
@MainActor
@Observable
final class MenuBarReadout {

    /// What the menu bar shows: volts and amps, or a dash when there is nothing.
    private(set) var title = "—"
    private(set) var isConnected = false

    static let updateInterval: TimeInterval = 0.5

    @ObservationIgnored private weak var controller: PSUController?
    @ObservationIgnored private var timer: Timer?

    init(controller: PSUController) {
        self.controller = controller
        start()
    }

    deinit {
        timer?.invalidate()
    }

    private func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        // Common mode, or the reading freezes for as long as a menu is open —
        // which is precisely when somebody is looking at it.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    /// Reads the controller and publishes only what changed.
    func sample() {
        guard let controller else { return }
        let connected = controller.isConnected
        if isConnected != connected { isConnected = connected }

        let text = connected ? Self.compactReading(of: controller) : "—"
        if title != text { title = text }
    }

    /// Volts and amps in the width a menu bar can hold.
    ///
    /// The panel's own `Format.current` gives milliamps to three decimals, which
    /// is right in front of a 58-point readout and three digits too many at the
    /// top of the screen next to the clock.
    static func compactReading(of controller: PSUController) -> String {
        let voltage = controller.voltageIsValid ? Format.number(controller.measuredVoltage, 3) + "V" : "—V"
        let current: String
        if controller.currentIsOverload {
            current = "OVLD"
        } else if !controller.currentIsValid {
            current = "—A"
        } else if abs(controller.measuredCurrent) < 1 {
            current = Format.number(controller.measuredCurrent * 1000, 1) + "mA"
        } else {
            current = Format.number(controller.measuredCurrent, 3) + "A"
        }
        return voltage + " " + current
    }
}

/// What sits in the menu bar itself.
///
/// A monospaced digit font, or the item resizes on every changing digit and
/// drags every menu to its right along with it.
///
/// The text is always drawn, including the dash that stands for "no supply".
/// An icon on its own until there is something to show makes the item
/// impossible to find: a small anonymous glyph among a dozen other small
/// anonymous glyphs, saying nothing about which app it belongs to. An item
/// nobody can find is not a feature, however correctly it is installed.
struct MenuBarLabel: View {
    let readout: MenuBarReadout

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
            Text(readout.title).monospacedDigit()
        }
    }
}

/// The menu bar item: the output in the bar, the detail behind it.
struct MenuBarReadoutContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var controller: PSUController { model.controller }

    var body: some View {
        Group {
            if controller.isConnected {
                Text("\(controller.identity?.model ?? "Supply") · \(controller.outputMode.label) · \(controller.isOutputEnabled ? "output on" : "output off")")
                Divider()
                row("Voltage", controller.voltageIsValid ? Format.number(controller.measuredVoltage, 3) + "V" : "—")
                row("Current", controller.currentIsValid ? Format.number(controller.measuredCurrent, 4) + "A" : "—")
                row("Power", controller.voltageIsValid && controller.currentIsValid
                    ? Format.number(controller.measuredPower, 3) + "W" : "—")
                row("Set", (controller.setVoltageReadback.map { Format.number($0, 3) + "V" } ?? "—")
                    + "  " + (controller.setCurrentReadback.map { Format.number($0, 4) + "A" } ?? "—"))
                row("OVP", controller.ovpLevel.map { Format.number($0, 2) + "V" } ?? "—")
                Text("Runtime \(Format.duration(controller.runtime)) · \(controller.voltageSampleCount) samples")
                if controller.protectionIsKnown && !controller.protection.isClear {
                    Text(controller.protection.trippedLabels.joined(separator: ", "))
                }
            } else {
                Text("No supply connected")
            }

            Divider()

            // Off, but never on. Cutting the output from another application is
            // the one thing worth doing without looking; putting volts back
            // across whatever is on the bench is not.
            Button("Switch Output Off") { controller.setOutput(enabled: false) }
                .disabled(!controller.isConnected || !controller.isOutputEnabled)
            Button("Clear Protection") { controller.clearProtection() }
                .disabled(!controller.isConnected)

            Divider()

            Button("Show Main Window") {
                openWindow(id: "main")
                NSApp.activate()
            }
            Button("Show Voltage Graph") {
                openWindow(id: GraphKind.voltage.windowID)
                NSApp.activate()
            }

            Divider()

            if controller.isConnected {
                Button("Disconnect") { controller.disconnect() }
            } else {
                Button("Connect…") {
                    model.isConnectionSheetPresented = true
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    /// A menu row is a single label; a `LabeledContent` would be drawn as one
    /// anyway, so the two halves are joined here with the value already
    /// formatted the way the readout panel formats it.
    private func row(_ name: String, _ text: String) -> some View {
        Text("\(name)   \(text)")
    }
}
