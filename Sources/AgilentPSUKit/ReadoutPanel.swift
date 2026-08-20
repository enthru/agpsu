import SwiftUI
import PSUCore

/// The instrument-style readout across the top of the window: measured voltage
/// and current, their set points, the regulation mode, the protection summary
/// and calculated power.
struct ReadoutPanel: View {
    @Environment(AppModel.self) private var model

    private var controller: PSUController { model.controller }
    private var textColor: Color { model.panelTextColor.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                reading(voltageText)
                Spacer(minLength: 12)
                reading(currentText)
            }

            HStack(alignment: .firstTextBaseline) {
                setPoint("Set: " + (controller.setVoltageReadback.map { Format.number($0, 3) + "V" } ?? "Invalid!"))
                Spacer(minLength: 12)
                setPoint("Set: " + (controller.setCurrentReadback.map { Format.number($0, 4) + "A" } ?? "Invalid!"))
            }

            HStack(alignment: .center, spacing: 16) {
                Text(controller.outputMode.label)
                    .font(.system(size: controller.outputMode.label.count > 3 ? 34 : 56, weight: .regular, design: .default))
                    .foregroundStyle(textColor)
                    .frame(minWidth: 110, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    Text("UVP:\(limitText(controller.uvpLevel, digits: 3, unit: "V"))")
                    Text("UCP:\(limitText(controller.ucpLevel, digits: 4, unit: "A"))")
                }
                .font(.system(size: 17))
                .foregroundStyle(textColor)

                VStack(alignment: .leading, spacing: 0) {
                    Text("OVP:\(controller.ovpLevel.map { Format.number($0, 2) + "V" } ?? "?")")
                    Text("OCP:\(controller.ocpEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "?")")
                }
                .font(.system(size: 17))
                .foregroundStyle(textColor)

                Spacer(minLength: 8)

                Text(powerText)
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.panelBackground.color)
    }

    private func reading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 58, weight: .regular))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
    }

    private func setPoint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22))
            .foregroundStyle(textColor)
            .lineLimit(1)
    }

    private var voltageText: String {
        guard controller.pollPlan.measureVoltage else { return "?" }
        guard controller.voltageIsValid else { return "?" }
        return Format.voltage(controller.measuredVoltage, range: controller.voltageRange)
    }

    private var currentText: String {
        guard controller.pollPlan.measureCurrent else { return "?" }
        if controller.currentIsOverload { return "OVLD.mA" }
        guard controller.currentIsValid else { return "?" }
        return Format.current(controller.measuredCurrent, range: controller.currentRange)
    }

    private var powerText: String {
        guard controller.voltageIsValid, controller.currentIsValid else { return "?" }
        return Format.power(controller.measuredPower, range: controller.powerRange)
    }

    private func limitText(_ value: Double?, digits: Int, unit: String) -> String {
        guard let value else { return "Dis" }
        return Format.number(value, digits) + unit
    }
}
