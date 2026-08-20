import SwiftUI
import PSUCore

/// The control boxes, in as many columns as the width allows.
///
/// Its own view so a test can render it at the size the window gives it and
/// check that everything fits without scrolling — which is the whole point of
/// the grid. The boxes used to be five stacked in one narrow column, which meant
/// scrolling past three of them to reach the fourth while two thirds of a wide
/// window sat empty.
struct ControlGrid: View {
    /// Two columns as soon as the pane is wide enough for them, one when it is
    /// not. Nothing here is tall, so wrapping costs nothing and saves the
    /// scroll. Three hundred is the width the panels were tightened to fit in.
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            SetPointBox(quantity: .voltage)
            SetPointBox(quantity: .current)
            OutputBox()
            ProtectionBox()
            DisplayBox()
        }
        .padding(10)
    }
}

/// A row inside a control panel: a short label, the controls after it, and the
/// row filling the width it was given.
///
/// The labels used to be the full name — "UVP (UnderVoltage Protection):" at a
/// fixed 190 points — which by itself was two thirds of a column. The name is
/// worth having once, so it moved to the tooltip and to the caption under the
/// box; the row keeps the abbreviation the front panel uses.
private struct PanelRow<Content: View>: View {
    let label: String
    var help: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
                .help(help)
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
                    label: "UVP",
                    help: "Under-voltage protection, in volts",
                    text: $uvpText,
                    set: { controller.setUVP(Double(uvpText)) },
                    clear: { controller.setUVP(nil); uvpText = "" }
                )

                protectionRow(
                    label: "UCP",
                    help: "Under-current protection, in amps",
                    text: $ucpText,
                    set: { controller.setUCP(Double(ucpText)) },
                    clear: { controller.setUCP(nil); ucpText = "" }
                )

                Text("Under-voltage and under-current protection are enforced by this app from the measured values, so they react no faster than the update rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .disabled(!controller.isConnected)
    }

    private func protectionRow(label: String,
                               help: String,
                               text: Binding<String>,
                               set: @escaping () -> Void,
                               clear: @escaping () -> Void) -> some View {
        PanelRow(label: label, help: help) {
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

                PanelRow(label: "OVP", help: "Over-voltage protection, in volts — inside the supply") {
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
                    Button("Clear Protect") { controller.clearProtection() }
                }

                PanelRow(label: "OCP", help: "Over-current protection — inside the supply") {
                    Button(controller.ocpEnabled == true ? "Enabled" : "Disabled") {
                        controller.toggleOCP()
                    }
                    .frame(width: 90)
                    Text(protectionSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(controller.protectionIsKnown && !controller.protection.isClear ? .red : .secondary)
                        .lineLimit(1)
                }

                Text("OVP and OCP run inside the supply and act immediately; Clear Protect resets a trip once the cause is gone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .disabled(!controller.isConnected)
    }

    private var protectionColor: Color {
        guard controller.protectionIsKnown else { return .secondary }
        return controller.protection.isClear ? .green : .red
    }

    /// What the questionable-status register says, in the words the event list
    /// uses — beside the switch rather than only in the list.
    private var protectionSummary: String {
        guard controller.protectionIsKnown else { return "status unknown" }
        let tripped = controller.protection.trippedLabels
        return tripped.isEmpty ? "clear" : tripped.joined(separator: ", ")
    }
}

/// Messages on the supply's own front panel display.
struct DisplayBox: View {
    @Environment(AppModel.self) private var model
    @State private var text = "Hello World!"

    private var controller: PSUController { model.controller }

    var body: some View {
        GroupBox("Front Panel") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 90)
                    Button("Send") { controller.sendDisplayText(text) }
                }
                HStack(spacing: 6) {
                    Button("Normal Display") { controller.clearDisplayText() }
                    Button(controller.frontPanelIsOn ? "Display Off" : "Display On") {
                        controller.toggleFrontPanel()
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 2)
        }
        .disabled(!controller.isConnected)
    }
}

/// The strip under the readout: what is connected, what it can do, how fast it
/// is being asked and what it last complained about.
///
/// This was a GroupBox in the column of controls, where four lines of
/// unchanging facts took the room of a control. Facts belong across the top,
/// where they are read at a glance and cost nothing but their own height.
struct InstrumentStrip: View {
    @Environment(AppModel.self) private var model
    @State private var rateText = ""

    private var controller: PSUController { model.controller }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(controller.isConnected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)

                Text(controller.identity?.model ?? "No supply")
                    .fontWeight(.medium)

                if let identity = controller.identity {
                    Text("\(Format.number(identity.maxVoltage, 2))V · \(Format.number(identity.maxCurrent, 3))A")
                        .foregroundStyle(.secondary)
                        .help("The supply's ratings, read at connection")
                }

                Text(controller.isConnected ? controller.portDisplayName : "not connected")
                    .foregroundStyle(.secondary)

                Divider().frame(height: 12)

                Text("Rate")
                    .foregroundStyle(.secondary)
                TextField("", text: $rateText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .onSubmit(applyRate)
                    .help("Seconds between polling passes")
                Button("Set", action: applyRate)
                    .controlSize(.mini)

                Divider().frame(height: 12)

                Text(controller.errorText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("The last entry read from the supply's error queue")
                Button("Get") { controller.readError() }
                    .controlSize(.mini)
                    .disabled(!controller.isConnected)

                Spacer()

                if !controller.isConnected {
                    Button("Connect…") { model.isConnectionSheetPresented = true }
                        .controlSize(.small)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            // Whatever the controller last refused to do, in the one place a
            // person is already looking. It used to sit at the bottom of a box
            // that could be scrolled off screen.
            if !controller.message.isEmpty {
                Text(controller.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12))
            }
        }
        .background(.bar)
        .onAppear { rateText = SCPI.format(controller.updateRate) }
        .onChange(of: controller.updateRate) { rateText = SCPI.format(controller.updateRate) }
    }

    private func applyRate() {
        guard let value = Double(rateText), value >= 0.05, value <= 3600 else {
            controller.append("Invalid update rate")
            rateText = SCPI.format(controller.updateRate)
            return
        }
        controller.updateRate = value
        controller.append("Update rate \(SCPI.format(value))s ")
    }
}
