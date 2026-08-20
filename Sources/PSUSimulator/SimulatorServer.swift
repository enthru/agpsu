import Foundation
import Darwin

/// Runs a `SimulatedPSU` behind a pseudo-terminal on a background thread.
///
/// Point the application at `devicePath` and it will talk to the simulator over
/// a genuine serial line discipline.
public final class SimulatorServer: @unchecked Sendable {
    public let devicePath: String

    private let terminal: PseudoTerminal
    private let psu: SimulatedPSU
    private let queue = DispatchQueue(label: "com.agpsu.simulator", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var pending = [UInt8]()

    /// Called with every command line received and every response sent — used by
    /// the CLI to print a live trace of the conversation.
    public var onTraffic: (@Sendable (_ received: String, _ replied: String?) -> Void)?

    public init(psu: SimulatedPSU = SimulatedPSU()) throws {
        self.psu = psu
        self.terminal = try PseudoTerminal()
        self.devicePath = terminal.slavePath
    }

    public var simulatedDevice: SimulatedPSU { psu }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.pump() }
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func pump() {
        var buffer = [UInt8](repeating: 0, count: 512)

        while isRunning {
            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                read(terminal.masterDescriptor, pointer.baseAddress!, pointer.count)
            }

            if count > 0 {
                pending.append(contentsOf: buffer[0..<count])
                drainLines()
                continue
            }

            // EIO means no process currently holds the slave open; EAGAIN means
            // nothing has arrived yet. Both are normal — wait and look again.
            if count <= 0 {
                if errno != EAGAIN && errno != EINTR && errno != EIO && count < 0 {
                    break
                }
                usleep(5000)
            }
        }
    }

    private func drainLines() {
        while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineBytes = Array(pending[pending.startIndex..<index])
            pending.removeSubrange(pending.startIndex...index)
            guard !lineBytes.isEmpty else { continue }

            let command = String(decoding: lineBytes, as: UTF8.self)
            let reply = psu.respond(to: command)
            if let reply {
                send(reply)
            }
            onTraffic?(command, reply)
        }
    }

    /// Real 663x supplies terminate their responses with CRLF.
    private func send(_ response: String) {
        let bytes = Array((response + "\r\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { pointer -> Int in
                write(terminal.masterDescriptor, pointer.baseAddress! + offset, bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else {
                if errno == EINTR || errno == EAGAIN {
                    usleep(1000)
                    continue
                }
                break
            }
        }
    }
}
