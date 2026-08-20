import Foundation

/// A single write-only action queued from the UI for the worker to perform on
/// its next pass. Queries are not queued — they are part of the polling plan.
public enum PSUJob: Sendable {
    /// Send a command, optionally logging a line once it has gone out.
    case command(String, log: String?)
    /// `*RST`, followed by a forced re-read of every setting.
    case reset
    /// Read one entry from the device's error queue.
    case readError
}

/// Which queries the worker performs each pass. Mirrors the Measurements menu:
/// switching a reading off both saves serial bandwidth and blanks its readout.
public struct PSUPollPlan: Sendable, Equatable, Codable {
    public var measureVoltage = true
    public var measureCurrent = true
    public var readOperationStatus = true
    public var readProtectionStatus = true
    public var readSetValues = true
    public var readProtectionLevels = true

    public init() {}
}

/// Everything one polling pass learned, handed to the main actor in one piece.
public struct PSUSnapshot: Sendable {
    public var timestamp = Date()
    public var voltage: Double?
    public var current: Double?
    public var currentOverload = false
    public var setVoltage: Double?
    public var setCurrent: Double?
    public var ovpLevel: Double?
    public var ocpEnabled: Bool?
    public var operationCondition: Int?
    public var questionableCondition: Int?
    public var errorText: String?
    public var logs: [String] = []
    public var failure: String?
}

/// Owns the serial device and does all blocking I/O on a private queue.
///
/// The Windows original drove the supply from a `DispatchTimer` on the UI
/// thread, so a slow or unplugged device froze the whole window. Here the UI
/// only ever receives finished snapshots.
public final class PSUWorker: @unchecked Sendable {
    private let device: PSUDevice
    private let queue = DispatchQueue(label: "com.agpsu.serial", qos: .userInitiated)
    private let lock = NSLock()

    private var jobs: [PSUJob] = []
    private var plan = PSUPollPlan()
    private var interval: TimeInterval = 1.0
    private var running = false

    private let onSnapshot: @Sendable (PSUSnapshot) -> Void

    public init(device: PSUDevice, onSnapshot: @escaping @Sendable (PSUSnapshot) -> Void) {
        self.device = device
        self.onSnapshot = onSnapshot
    }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.cycle() }
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
        // Closing is queued rather than waited on: a pass already blocked on a
        // read could take seconds to time out, and the UI must not freeze with
        // it. The in-flight pass finishes first, then the port closes.
        queue.async { [device] in
            device.close()
        }
    }

    public func enqueue(_ job: PSUJob) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
    }

    public func update(plan newPlan: PSUPollPlan) {
        lock.lock()
        plan = newPlan
        lock.unlock()
    }

    public func update(interval newInterval: TimeInterval) {
        lock.lock()
        interval = max(0.05, newInterval)
        lock.unlock()
    }

    private func snapshotSettings() -> (running: Bool, plan: PSUPollPlan, interval: TimeInterval, jobs: [PSUJob]) {
        lock.lock()
        defer { lock.unlock() }
        let pending = jobs
        jobs.removeAll(keepingCapacity: true)
        return (running, plan, interval, pending)
    }

    private func cycle() {
        let started = Date()
        let settings = snapshotSettings()
        guard settings.running else { return }

        var snapshot = PSUSnapshot(timestamp: started)

        do {
            try run(jobs: settings.jobs, into: &snapshot)
            poll(plan: settings.plan, into: &snapshot)
        } catch {
            snapshot.failure = error.localizedDescription
        }

        onSnapshot(snapshot)

        if snapshot.failure != nil {
            lock.lock(); running = false; lock.unlock()
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        let delay = max(0, settings.interval - elapsed)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let stillRunning = { self.lock.lock(); defer { self.lock.unlock() }; return self.running }()
            if stillRunning { self.cycle() }
        }
    }

    private func run(jobs: [PSUJob], into snapshot: inout PSUSnapshot) throws {
        for job in jobs {
            switch job {
            case .command(let text, let log):
                try device.send(text)
                if let log { snapshot.logs.append(log) }

            case .reset:
                try device.send(SCPI.reset)
                snapshot.logs.append("Send Reset")

            case .readError:
                if let response = device.query(SCPI.errorQuery) {
                    snapshot.errorText = response
                    snapshot.logs.append(response)
                } else {
                    snapshot.errorText = "?"
                }
            }
        }
    }

    private func poll(plan: PSUPollPlan, into snapshot: inout PSUSnapshot) {
        if plan.measureVoltage {
            snapshot.voltage = device.queryNumber(SCPI.measureVoltage)
        }

        if plan.measureCurrent {
            if let value = device.queryNumber(SCPI.measureCurrent) {
                if SCPIParse.isOverload(value) {
                    // 9.91E+37 means "off scale for the selected current range".
                    snapshot.currentOverload = true
                    snapshot.current = 0
                } else {
                    snapshot.current = value
                }
            }
        }

        if plan.readOperationStatus {
            snapshot.operationCondition = SCPIParse.integer(device.query(SCPI.operationCondition))
        }

        if plan.readProtectionStatus {
            snapshot.questionableCondition = SCPIParse.integer(device.query(SCPI.questionableCondition))
        }

        if plan.readSetValues {
            snapshot.setVoltage = device.queryNumber(SCPI.setVoltageQuery)
            snapshot.setCurrent = device.queryNumber(SCPI.setCurrentQuery)
        }

        if plan.readProtectionLevels {
            snapshot.ovpLevel = device.queryNumber(SCPI.ovpQuery)
            if let state = SCPIParse.integer(device.query(SCPI.ocpStateQuery)) {
                snapshot.ocpEnabled = state != 0
            }
        }
    }
}
