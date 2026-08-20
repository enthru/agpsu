import SwiftUI
import PSUCore

/// Voltage or current entry: a value field, up/down stepping by a chosen
/// increment, a V/mV (or A/mA) unit selector and an Enter button.
struct SetPointBox: View {
    enum Quantity {
        case voltage, current

        var title: String { self == .voltage ? "Voltage" : "Current" }
        var baseUnit: String { self == .voltage ? "V" : "A" }
        var milliUnit: String { self == .voltage ? "mV" : "mA" }
    }

    let quantity: Quantity
    @Environment(AppModel.self) private var model

    @State private var text = "0"
    @State private var useMilli = false
    @State private var increment = 1.0

    private static let increments: [Double] = [2, 1, 0.5, 0.25]

    var body: some View {
        GroupBox(quantity.title) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 90)
                        .onSubmit(commit)

                    Stepper("", onIncrement: { step(+1) }, onDecrement: { step(-1) })
                        .labelsHidden()
                }

                HStack(spacing: 6) {
                    Picker("", selection: $useMilli) {
                        Text(quantity.baseUnit).tag(false)
                        Text(quantity.milliUnit).tag(true)
                    }
                    .labelsHidden()
                    .frame(width: 66)

                    Picker("", selection: $increment) {
                        ForEach(Self.increments, id: \.self) { value in
                            Text(shortNumber(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 78)

                    Button("Enter", action: commit)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 2)
        }
        .disabled(!model.controller.isConnected)
    }

    private var upperLimit: Double {
        guard let identity = model.controller.identity else { return 0 }
        let base = quantity == .voltage ? identity.maxVoltage : identity.maxCurrent
        return useMilli ? base * 1000 : base
    }

    private func step(_ direction: Double) {
        let current = Double(text) ?? 0
        let next = min(max(current + direction * increment, 0), upperLimit)
        text = trimmed(next)
        commit()
    }

    private func commit() {
        guard let value = Double(text) else {
            model.controller.append("Invalid \(quantity.title) input")
            return
        }
        let clamped = min(max(value, 0), upperLimit)
        if clamped != value { text = trimmed(clamped) }

        switch quantity {
        case .voltage: model.controller.setVoltage(clamped, inMillivolts: useMilli)
        case .current: model.controller.setCurrent(clamped, inMilliamps: useMilli)
        }
    }

    private func trimmed(_ value: Double) -> String {
        SCPI.format(value)
    }

    private func shortNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// Output on/off plus the two software protections this application enforces.
struct OutputBox: View {
    @Environment(AppModel.self) private var model

    @State private var uvpText = ""
    @State private var ucpText = ""

    private var controller: PSUController { model.controller }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.isOutputEnabled ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text("Output").font(.headline)
                    Spacer()
                    Button(controller.isOutputEnabled ? "Output Off" : "Output On") {
                        controller.toggleOutput()
                    }
                    .tint(controller.isOutputEnabled ? .red : .green)
                }

                protectionRow(
                    label: "UVP (UnderVoltage Protection):",
                    text: $uvpText,
                    set: { controller.setUVP(Double(uvpText)) },
                    clear: { controller.setUVP(nil); uvpText = "" }
                )

                protectionRow(
                    label: "UCP (UnderCurrent Protection):",
                    text: $ucpText,
                    set: { controller.setUCP(Double(ucpText)) },
                    clear: { controller.setUCP(nil); ucpText = "" }
                )

                Text("UVP and UCP are enforced by this app from the measured values, so they react no faster than the update rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .disabled(!controller.isConnected)
    }

    private func protectionRow(label: String, text: Binding<String>, set: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 190, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 66)
            Button("Set", action: set)
            Button("Clear", action: clear)
        }
    }
}

/// OVP and OCP — these live in the supply itself.
struct ProtectionBox: View {
    @Environment(AppModel.self) private var model
    @State private var ovpText = ""

    private var controller: PSUController { model.controller }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(protectionColor)
                        .frame(width: 12, height: 12)
                    Text("Protection").font(.headline)
                    Spacer()
                    Toggle("Beep on trip", isOn: Binding(
                        get: { controller.beeperEnabled },
                        set: { controller.beeperEnabled = $0 }
                    ))
                    .toggleStyle(.checkbox)
                }

                HStack(spacing: 6) {
                    Text("OVP (OverVoltage Protection):")
                        .font(.system(size: 11))
                        .frame(width: 190, alignment: .leading)
                    TextField("", text: $ovpText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 66)
                    Button("Set") {
                        if let value = Double(ovpText) {
                            controller.setOVP(value)
                        } else {
                            controller.append("Invalid OVP value")
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text("OCP (OverCurrent Protection):")
                        .font(.system(size: 11))
                        .frame(width: 190, alignment: .leading)
                    Button(controller.ocpEnabled == true ? "Enabled" : "Disabled") {
                        controller.toggleOCP()
                    }
                    .frame(width: 90)
                    Button("Clear Protect") { controller.clearProtection() }
                }
            }
            .padding(.top, 2)
        }
        .disabled(!controller.isConnected)
    }

    private var protectionColor: Color {
        guard controller.protectionIsKnown else { return .secondary }
        return controller.protection.isClear ? .green : .red
    }
}

/// Messages on the supply's own front panel display.
struct DisplayBox: View {
    @Environment(AppModel.self) private var model
    @State private var text = "Hello World!"

    private var controller: PSUController { model.controller }

    var body: some View {
        GroupBox("Display") {
            HStack(spacing: 6) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120)
                Button("Send") { controller.sendDisplayText(text) }
                Button("Clear") { controller.clearDisplayText() }
                Button(controller.frontPanelIsOn ? "Display Off" : "Display On") {
                    controller.toggleFrontPanel()
                }
            }
            .padding(.top, 2)
        }
        .disabled(!controller.isConnected)
    }
}

/// Connection facts, the polling rate and the supply's error queue.
struct InfoBox: View {
    @Environment(AppModel.self) private var model
    @State private var rateText = "1"

    private var controller: PSUController { model.controller }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.isConnected ? Color.green : Color.secondary)
                        .frame(width: 12, height: 12)
                    Text("Info").font(.headline)
                    Spacer()
                }

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model: \(controller.identity?.model ?? "—")")
                        Text("Max Voltage: \(controller.identity.map { Format.number($0.maxVoltage, 3) } ?? "—")")
                        Text("Max Current: \(controller.identity.map { Format.number($0.maxCurrent, 4) } ?? "—")")
                        Text("Connection: \(controller.isConnected ? controller.portDisplayName : "not connected")")
                    }
                    .font(.system(size: 11))

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Update Rate (sec):").font(.system(size: 11))
                            TextField("", text: $rateText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 54)
                            Button("Set") {
                                if let value = Double(rateText), value >= 0.05, value <= 3600 {
                                    controller.updateRate = value
                                    controller.append("Update rate \(SCPI.format(value))s ")
                                } else {
                                    controller.append("Invalid update rate")
                                }
                            }
                        }
                        HStack(spacing: 6) {
                            Text("Error:").font(.system(size: 11))
                            Text(controller.errorText)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .frame(minWidth: 130, alignment: .leading)
                            Button("Get") { controller.readError() }
                        }
                    }
                }

                if !controller.message.isEmpty {
                    Text(controller.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 2)
        }
    }
}
