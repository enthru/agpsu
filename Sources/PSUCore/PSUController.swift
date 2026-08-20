import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

public struct LogEntry: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

public enum CurrentMeasurementRange: String, Sendable {
    case low
    case high
}

/// The application's single source of truth: connection state, the latest
/// readings, protections, logging and the three graph histories.
///
/// All mutation happens on the main actor. Serial traffic lives in `PSUWorker`,
/// which hands finished snapshots back here.
@MainActor
@Observable
public final class PSUController {

    // MARK: Connection

    public private(set) var isConnected = false
    public private(set) var identity: DeviceIdentity?
    public private(set) var config = SerialConfig()
    public private(set) var connectionError: String?

    public var deviceTitle: String {
        identity.map { "\($0.model) System DC Power Supply" } ?? "System DC Power Supply"
    }

    public var portDisplayName: String {
        (config.path as NSString).lastPathComponent
    }

    // MARK: Live readings

    public private(set) var measuredVoltage: Double = 0
    public private(set) var measuredCurrent: Double = 0
    public private(set) var measuredPower: Double = 0
    public private(set) var voltageIsValid = false
    public private(set) var currentIsValid = false
    public private(set) var currentIsOverload = false

    public private(set) var setVoltageReadback: Double?
    public private(set) var setCurrentReadback: Double?
    public private(set) var ovpLevel: Double?
    public private(set) var ocpEnabled: Bool?
    public private(set) var outputMode: OutputMode = .disabled
    public private(set) var protection = ProtectionStatus(condition: 0)
    public private(set) var protectionIsKnown = false
    public private(set) var isOutputEnabled = false
    public private(set) var errorText = "?"

    /// Where alerts go — a notification banner in the application, nothing at
    /// all in a test. Weak: the presenter belongs to whoever made it.
    public weak var alerts: AlertPresenter?
    public private(set) var message = ""

    // MARK: Counters

    public private(set) var voltageSampleCount = 0
    public private(set) var currentSampleCount = 0
    public private(set) var runtime: TimeInterval = 0
    public private(set) var progress: Double = 0
    public var progressMaximum: Double = 100

    // MARK: Soft protections (evaluated by this app, not the supply)

    public private(set) var uvpLevel: Double?
    public private(set) var ucpLevel: Double?
    public var beeperEnabled = true

    // MARK: Display ranges

    public var voltageRange = DisplayRange()
    public var currentRange = DisplayRange()
    public var powerRange = DisplayRange()

    // MARK: Polling plan

    public var pollPlan = PSUPollPlan() {
        didSet { worker?.update(plan: pollPlan) }
    }

    public var updateRate: TimeInterval = 1.0 {
        didSet { worker?.update(interval: updateRate) }
    }

    public private(set) var measurementRange: CurrentMeasurementRange = .high

    // MARK: Event list

    public private(set) var entries: [LogEntry] = []
    public var autoScroll = true
    public var updateList = true
    public var addMeasurementsToList = false
    private var entryCounter = 0
    private static let maximumEntries = 5000

    // MARK: Graphs

    public var voltageHistory = SampleBuffer()
    public var currentHistory = SampleBuffer()
    public var powerHistory = SampleBuffer()

    // MARK: Data logging

    public var logOutputText = false
    public var logOutputCSV = false
    public var logStatusText = false
    public private(set) var logDirectory = DataLogger.defaultDirectory

    // MARK: Private

    private var worker: PSUWorker?
    private var logger: DataLogger?
    private var runtimeTimer: Timer?

    public init() {}

    // MARK: - Connection lifecycle

    public func connect(config: SerialConfig, identity: DeviceIdentity) {
        disconnect()

        let device = PSUDevice(config: config)
        do {
            try device.open()
        } catch {
            connectionError = error.localizedDescription
            append("Connect failed: \(error.localizedDescription)")
            return
        }

        self.config = config
        self.identity = identity
        self.connectionError = nil
        self.isConnected = true
        self.runtime = 0
        self.ovpLevel = identity.maxOVP

        logger = DataLogger(configuration: .init(
            directory: logDirectory,
            model: identity.model,
            portName: config.path
        ))

        let worker = PSUWorker(device: device) { snapshot in
            Task { @MainActor [weak self] in
                self?.apply(snapshot)
            }
        }
        worker.update(plan: pollPlan)
        worker.update(interval: updateRate)
        worker.start()
        self.worker = worker

        startRuntimeTimer()
        append("Connected to \(identity.model) on \(portDisplayName)")
    }

    public func disconnect() {
        runtimeTimer?.invalidate()
        runtimeTimer = nil

        if let worker {
            worker.stop()
            self.worker = nil
            append("Disconnected")
        }
        logger?.closeAll()
        logger = nil
        isConnected = false
    }

    private func startRuntimeTimer() {
        runtimeTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.isConnected else { return }
                self.runtime += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        runtimeTimer = timer
    }

    // MARK: - Snapshot handling

    private func apply(_ snapshot: PSUSnapshot) {
        // A pass already under way when the user disconnected can still deliver.
        guard isConnected else { return }

        for line in snapshot.logs {
            append(line)
        }

        if let failure = snapshot.failure {
            connectionError = failure
            append("Connection lost: \(failure)")
            raise(.connectionLost,
                  title: "\(identity?.model ?? "The supply") stopped answering",
                  body: failure)
            disconnect()
            return
        }

        applyVoltage(snapshot)
        applyCurrent(snapshot)
        applyPower()

        if pollPlan.readSetValues {
            setVoltageReadback = snapshot.setVoltage
            setCurrentReadback = snapshot.setCurrent
        }

        if pollPlan.readProtectionLevels {
            if let level = snapshot.ovpLevel { ovpLevel = level }
            if let enabled = snapshot.ocpEnabled { ocpEnabled = enabled }
        }

        if pollPlan.readOperationStatus {
            if let condition = snapshot.operationCondition {
                let mode = OutputMode.decode(condition)
                if case .unknown = mode {
                    append("STAT:OPER:COND? = \(condition)")
                }
                noteRegulation(leaving: outputMode, entering: mode)
                outputMode = mode
                isOutputEnabled = mode.isOutputEnabled
            } else {
                outputMode = .unknown(-1)
            }
        }

        if pollPlan.readProtectionStatus {
            applyProtection(snapshot)
        }

        if let error = snapshot.errorText {
            errorText = error
        }

        recordHistory(at: snapshot.timestamp)
        evaluateSoftProtections()
        writeMeasurementLogs(at: snapshot.timestamp)
        advanceProgress()

        if addMeasurementsToList && voltageIsValid && currentIsValid {
            append("\(Format.number(measuredVoltage, 3))V   \(Format.number(measuredCurrent, 4))A   ")
        }
    }

    private func applyVoltage(_ snapshot: PSUSnapshot) {
        guard pollPlan.measureVoltage else {
            measuredVoltage = 0
            voltageIsValid = false
            return
        }
        if let value = snapshot.voltage, !SCPIParse.isOverload(value) {
            measuredVoltage = value
            voltageIsValid = true
            voltageSampleCount += 1
        } else {
            measuredVoltage = 0
            voltageIsValid = false
        }
    }

    private func applyCurrent(_ snapshot: PSUSnapshot) {
        guard pollPlan.measureCurrent else {
            measuredCurrent = 0
            currentIsValid = false
            currentIsOverload = false
            return
        }
        currentIsOverload = snapshot.currentOverload
        if snapshot.currentOverload {
            measuredCurrent = 0
            currentIsValid = false
            currentSampleCount += 1
        } else if let value = snapshot.current {
            measuredCurrent = value
            currentIsValid = true
            currentSampleCount += 1
        } else {
            measuredCurrent = 0
            currentIsValid = false
        }
    }

    private func applyPower() {
        measuredPower = (voltageIsValid && currentIsValid) ? measuredVoltage * measuredCurrent : 0
    }

    private func applyProtection(_ snapshot: PSUSnapshot) {
        guard let condition = snapshot.questionableCondition else {
            protectionIsKnown = false
            return
        }
        let status = ProtectionStatus(condition: condition)
        let wasClear = protection.isClear || !protectionIsKnown
        protection = status
        protectionIsKnown = true

        // Log a trip once per event rather than on every polling pass.
        if !status.isClear && wasClear {
            for label in status.trippedLabels {
                append(label)
            }
            isOutputEnabled = false
            beep()
            raise(.protectionTripped,
                  title: status.trippedLabels.first ?? "Protection tripped",
                  body: "\(identity?.model ?? "The supply") shut its output down: \(status.trippedLabels.joined(separator: ", ")).")
        }
    }

    /// The edge into current limit, not the state: a supply can sit in CC for
    /// hours quite happily, and one banner per polling pass is a fault of its
    /// own. Only worth saying while the output is actually on.
    private func noteRegulation(leaving previous: OutputMode, entering mode: OutputMode) {
        guard mode.isCurrentLimited, !previous.isCurrentLimited else { return }
        raise(.wentToConstantCurrent,
              title: "Output went to constant current",
              body: "\(identity?.model ?? "The supply") is holding \(Format.number(measuredCurrent, 4))A at \(Format.number(measuredVoltage, 3))V — the load is taking the whole limit.")
    }

    private func recordHistory(at timestamp: Date) {
        if voltageIsValid {
            voltageHistory.append(value: measuredVoltage, at: timestamp)
        }
        if currentIsValid {
            currentHistory.append(value: measuredCurrent, at: timestamp)
        }
        if voltageIsValid && currentIsValid {
            powerHistory.append(value: measuredPower, at: timestamp)
        }
    }

    private func advanceProgress() {
        progress += 1
        if progress >= progressMaximum {
            progress = 0
        }
    }

    // MARK: - Soft protections

    /// UVP and UCP are enforced by this application, not by the supply: it has no
    /// under-voltage or under-current protection of its own. They can therefore
    /// only act as fast as the update rate allows.
    private func evaluateSoftProtections() {
        if let level = uvpLevel, voltageIsValid, Format.round(level, 3) > Format.round(measuredVoltage, 3) {
            trip(label: "UVP Tripped")
            uvpLevel = nil
        }

        if let level = ucpLevel, currentIsValid, Format.round(level, 4) > Format.round(measuredCurrent, 4) {
            trip(label: "UCP Tripped")
            ucpLevel = nil
        }
    }

    private func trip(label: String) {
        worker?.enqueue(.command(SCPI.outputOff, log: nil))
        append(label)
        append("T: \(Format.number(measuredVoltage, 3))V \(Format.number(measuredCurrent, 4))A ")
        isOutputEnabled = false
        beep()
        raise(.protectionTripped,
              title: label,
              body: "The output was switched off at \(Format.number(measuredVoltage, 3))V \(Format.number(measuredCurrent, 4))A.")
    }

    /// Hands an alert to the presenter, if there is one and it wants this kind.
    /// Building the message is not free — it formats two readings — so the
    /// question is asked first.
    private func raise(_ kind: PSUAlert.Kind, title: String, body: @autoclosure () -> String) {
        guard let alerts, alerts.wantsAlert(of: kind) else { return }
        alerts.present(PSUAlert(kind: kind, title: title, body: body()))
    }

    private func beep() {
        guard beeperEnabled else { return }
        #if canImport(AppKit)
        NSSound.beep()
        #endif
    }

    // MARK: - Commands

    public func setVoltage(_ value: Double, inMillivolts: Bool) {
        let volts = inMillivolts ? value / 1000 : value
        enqueue(SCPI.setVoltage(volts), log: "Set \(SCPI.format(volts))V ")
    }

    public func setCurrent(_ value: Double, inMilliamps: Bool) {
        let amps = inMilliamps ? value / 1000 : value
        enqueue(SCPI.setCurrent(amps), log: "Set \(SCPI.format(amps))A ")
    }

    public func toggleOutput() {
        if isOutputEnabled {
            enqueue(SCPI.outputOff, log: "Set Output Off ")
            isOutputEnabled = false
        } else {
            enqueue(SCPI.outputOn, log: "Set Output On ")
            isOutputEnabled = true
        }
    }

    public func setOutput(enabled: Bool) {
        guard enabled != isOutputEnabled else { return }
        toggleOutput()
    }

    public func clearProtection() {
        enqueue(SCPI.clearProtection, log: "Protect Clear  ")
    }

    public func toggleOCP() {
        let enable = !(ocpEnabled ?? false)
        enqueue(enable ? SCPI.ocpEnable : SCPI.ocpDisable, log: enable ? "OCP Enabled " : "OCP Disabled ")
        ocpEnabled = enable
    }

    /// The supply rejects an OVP above its rating, so the value is checked here
    /// first and reported in the event list instead of ending up in the error queue.
    public func setOVP(_ value: Double) {
        guard let identity else { return }
        guard value > 0, value <= identity.maxOVP else {
            append("Invalid OVP value")
            message = "OVP must be between 0 and \(Format.number(identity.maxOVP, 2))V."
            return
        }
        message = ""
        enqueue(SCPI.setOVP(value), log: "Set OVP: \(SCPI.format(value))V ")
    }

    public func setUVP(_ value: Double?) {
        guard let value else {
            uvpLevel = nil
            append("UVP Disabled ")
            return
        }
        guard value >= 0 else {
            message = "Error: Invalid UVP value"
            return
        }
        message = ""
        uvpLevel = value
        append("UVP Set: \(SCPI.format(value))V ")
    }

    public func setUCP(_ value: Double?) {
        guard let value else {
            ucpLevel = nil
            append("UCP Disabled ")
            return
        }
        guard value >= 0 else {
            message = "Error: Invalid UCP value"
            return
        }
        message = ""
        ucpLevel = value
        append("UCP Set: \(SCPI.format(value))A ")
    }

    public func sendDisplayText(_ text: String) {
        enqueue(SCPI.displayModeText, log: nil)
        enqueue(SCPI.displayText(text), log: "\(text) ")
    }

    public func clearDisplayText() {
        enqueue(SCPI.displayModeNormal, log: "Display Normal ")
    }

    public private(set) var frontPanelIsOn = true

    public func toggleFrontPanel() {
        frontPanelIsOn.toggle()
        enqueue(frontPanelIsOn ? SCPI.displayOn : SCPI.displayOff,
                log: frontPanelIsOn ? "Display On " : "Display Off ")
    }

    public func setMeasurementRange(_ range: CurrentMeasurementRange) {
        measurementRange = range
        switch range {
        case .high:
            enqueue(SCPI.currentRangeHigh, log: "C Meas Range High ")
        case .low:
            enqueue(SCPI.currentRangeLow, log: "C Meas Range Low ")
        }
    }

    public func resetDevice() {
        worker?.enqueue(.reset)
        ocpEnabled = false
        uvpLevel = nil
        ucpLevel = nil
    }

    public func readError() {
        worker?.enqueue(.readError)
    }

    private func enqueue(_ command: String, log: String?) {
        guard let worker else {
            message = "Not connected."
            return
        }
        worker.enqueue(.command(command, log: log))
    }

    // MARK: - Event list

    public func append(_ text: String) {
        let stamped = "\(text),\(DateFormatter.eventTimestamp.string(from: Date()))"

        if logStatusText {
            logger?.appendStatus(stamped)
        }

        guard updateList else { return }
        entryCounter += 1
        entries.append(LogEntry(id: entryCounter, text: stamped))
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
    }

    public func clearEntries() {
        entries.removeAll()
    }

    // MARK: - Counters

    public func resetRuntime() {
        runtime = 0
    }

    public func resetVoltageSamples() {
        voltageSampleCount = 0
    }

    /// Throws away the three graph histories and the counters that go with
    /// them — what you want at the top of a run rather than between two.
    public func resetHistory() {
        voltageHistory.reset()
        currentHistory.reset()
        powerHistory.reset()
        voltageSampleCount = 0
        currentSampleCount = 0
        progress = 0
    }

    public func resetCurrentSamples() {
        currentSampleCount = 0
    }

    // MARK: - Data logging

    public func setLogDirectory(_ url: URL) {
        logDirectory = url
        if let identity {
            logger?.update(configuration: .init(directory: url, model: identity.model, portName: config.path))
        }
    }

    private func writeMeasurementLogs(at timestamp: Date) {
        guard logOutputText || logOutputCSV else { return }
        guard voltageIsValid, currentIsValid else { return }

        let voltage = Format.number(measuredVoltage, 5)
        let current = Format.number(measuredCurrent, 5)

        if logOutputText {
            let stamp = DateFormatter.textLogTimestamp.string(from: timestamp)
            logger?.appendOutputText("\(stamp),\(Format.number(measuredVoltage, 4)),\(current)")
        }
        if logOutputCSV {
            let stamp = DateFormatter.logTimestamp.string(from: timestamp)
            logger?.appendOutputCSV("\(stamp),\(voltage),\(current)")
        }
        if let failure = logger?.lastError {
            message = "Log write failed: \(failure)"
        }
    }
}
