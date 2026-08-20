import Foundation
import Darwin

/// Parity modes supported by macOS `termios`.
///
/// The Windows original also offered Mark and Space parity. Darwin's termios has
/// no `CMSPAR`, so those two are not available here; the 663x supplies do not use
/// them (their RS-232 menu offers None/Even/Odd only).
public enum SerialParity: Int, CaseIterable, Codable, Sendable {
    case none = 0
    case odd = 1
    case even = 2

    public var label: String {
        switch self {
        case .none: return "None"
        case .odd: return "Odd"
        case .even: return "Even"
        }
    }
}

public enum SerialStopBits: Int, CaseIterable, Codable, Sendable {
    case one = 1
    case two = 2

    public var label: String { self == .one ? "1" : "2" }
}

public enum SerialFlowControl: Int, CaseIterable, Codable, Sendable {
    case none = 0
    case xonXoff = 1
    case hardware = 2

    public var label: String {
        switch self {
        case .none: return "None"
        case .xonXoff: return "Xon/Xoff"
        case .hardware: return "Hardware"
        }
    }
}

public struct SerialConfig: Codable, Sendable, Equatable {
    public var path: String
    public var baudRate: Int
    public var dataBits: Int
    public var parity: SerialParity
    public var stopBits: SerialStopBits
    public var flowControl: SerialFlowControl
    /// Maximum time to wait for a complete response line.
    public var readTimeout: TimeInterval
    public var writeTimeout: TimeInterval

    public static let supportedBaudRates = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200]
    public static let supportedDataBits = [5, 6, 7, 8]

    public init(path: String = "",
                baudRate: Int = 9600,
                dataBits: Int = 8,
                parity: SerialParity = .none,
                stopBits: SerialStopBits = .one,
                flowControl: SerialFlowControl = .none,
                readTimeout: TimeInterval = 2.0,
                writeTimeout: TimeInterval = 2.0) {
        self.path = path
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flowControl = flowControl
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
    }
}

public enum SerialError: Error, LocalizedError, Equatable {
    case openFailed(path: String, errno: Int32)
    case notOpen
    case configFailed(stage: String, errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code):
            let reason = String(cString: strerror(code))
            if code == EBUSY {
                return "\(path) is already in use by another program."
            }
            if code == ENOENT {
                return "\(path) does not exist."
            }
            if code == EACCES {
                return "No permission to open \(path)."
            }
            return "Cannot open \(path): \(reason)."
        case .notOpen:
            return "The serial port is not open."
        case .configFailed(let stage, let code):
            return "Serial configuration failed at \(stage): \(String(cString: strerror(code)))."
        case .writeFailed(let code):
            return "Serial write failed: \(String(cString: strerror(code)))."
        case .readFailed(let code):
            return "Serial read failed: \(String(cString: strerror(code)))."
        case .timedOut:
            return "Timed out waiting for a response from the device."
        }
    }
}

/// A blocking, line oriented RS-232 port built directly on POSIX `termios`.
///
/// This is the macOS replacement for `System.IO.Ports.SerialPort`. Like the .NET
/// class it defaults to `"\n"` as the line terminator: commands are sent with a
/// trailing LF and `readLine` returns everything up to the next LF. The 663x
/// supplies answer with CRLF, so callers should trim the leftover CR — exactly
/// what the original code did with its `TrimEnd()` calls.
///
/// Not thread safe: drive one port from one thread (the polling worker).
public final class SerialPort {
    private var fd: Int32 = -1
    private var savedTermios = termios()
    private var pending: [UInt8] = []

    public private(set) var config: SerialConfig
    public var isOpen: Bool { fd >= 0 }

    public init(config: SerialConfig) {
        self.config = config
    }

    deinit {
        close()
    }

    public func open() throws {
        guard fd < 0 else { return }

        // O_NONBLOCK keeps open() from hanging on a port whose DCD is low; it is
        // cleared again once the line is configured.
        let handle = Darwin.open(config.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            throw SerialError.openFailed(path: config.path, errno: errno)
        }

        // Claim the port so a second instance of the app cannot fight over it.
        if ioctl(handle, TIOCEXCL) == -1 {
            let code = errno
            Darwin.close(handle)
            throw SerialError.openFailed(path: config.path, errno: code)
        }

        if fcntl(handle, F_SETFL, 0) == -1 {
            let code = errno
            Darwin.close(handle)
            throw SerialError.configFailed(stage: "fcntl", errno: code)
        }

        guard tcgetattr(handle, &savedTermios) == 0 else {
            let code = errno
            Darwin.close(handle)
            throw SerialError.configFailed(stage: "tcgetattr", errno: code)
        }

        var options = savedTermios
        cfmakeraw(&options)

        options.c_cflag |= tcflag_t(CREAD | CLOCAL)
        options.c_cflag &= ~tcflag_t(CSIZE)
        switch config.dataBits {
        case 5: options.c_cflag |= tcflag_t(CS5)
        case 6: options.c_cflag |= tcflag_t(CS6)
        case 7: options.c_cflag |= tcflag_t(CS7)
        default: options.c_cflag |= tcflag_t(CS8)
        }

        switch config.parity {
        case .none:
            options.c_cflag &= ~tcflag_t(PARENB | PARODD)
        case .even:
            options.c_cflag |= tcflag_t(PARENB)
            options.c_cflag &= ~tcflag_t(PARODD)
        case .odd:
            options.c_cflag |= tcflag_t(PARENB | PARODD)
        }

        if config.stopBits == .two {
            options.c_cflag |= tcflag_t(CSTOPB)
        } else {
            options.c_cflag &= ~tcflag_t(CSTOPB)
        }

        switch config.flowControl {
        case .none:
            options.c_cflag &= ~tcflag_t(CRTSCTS)
            options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        case .xonXoff:
            options.c_cflag &= ~tcflag_t(CRTSCTS)
            options.c_iflag |= tcflag_t(IXON | IXOFF)
        case .hardware:
            options.c_cflag |= tcflag_t(CRTSCTS)
            options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        }

        // Fully non-blocking reads: `readLine` does its own deadline bookkeeping.
        options.c_cc.16 = 0 // VMIN
        options.c_cc.17 = 1 // VTIME, tenths of a second

        guard cfsetspeed(&options, speed_t(config.baudRate)) == 0 else {
            let code = errno
            Darwin.close(handle)
            throw SerialError.configFailed(stage: "cfsetspeed", errno: code)
        }

        guard tcsetattr(handle, TCSANOW, &options) == 0 else {
            let code = errno
            Darwin.close(handle)
            throw SerialError.configFailed(stage: "tcsetattr", errno: code)
        }

        fd = handle
        pending.removeAll(keepingCapacity: true)
        tcflush(fd, TCIOFLUSH)
    }

    public func close() {
        guard fd >= 0 else { return }
        tcdrain(fd)
        tcsetattr(fd, TCSANOW, &savedTermios)
        Darwin.close(fd)
        fd = -1
        pending.removeAll(keepingCapacity: true)
    }

    /// Discards anything the device has already queued but nobody asked for.
    /// Called before a query so a stale reply cannot be mistaken for the answer.
    public func flushInput() {
        guard fd >= 0 else { return }
        tcflush(fd, TCIFLUSH)
        pending.removeAll(keepingCapacity: true)
    }

    /// Writes `command` followed by LF and waits for it to leave the UART.
    public func writeLine(_ command: String) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        let bytes = Array((command + "\n").utf8)
        let deadline = Date().addingTimeInterval(config.writeTimeout)
        var offset = 0

        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                Darwin.write(fd, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    if Date() > deadline { throw SerialError.timedOut }
                    usleep(2000)
                    continue
                }
                throw SerialError.writeFailed(errno: errno)
            }
            if Date() > deadline { throw SerialError.timedOut }
        }
        tcdrain(fd)
    }

    /// Reads up to the next LF. Returns the line without its terminator, with any
    /// trailing CR removed. Throws `.timedOut` if the device stays quiet.
    public func readLine() throws -> String {
        guard fd >= 0 else { throw SerialError.notOpen }
        let deadline = Date().addingTimeInterval(config.readTimeout)
        var buffer = [UInt8](repeating: 0, count: 512)

        while true {
            if let index = pending.firstIndex(of: 0x0A) {
                let lineBytes = Array(pending[pending.startIndex..<index])
                pending.removeSubrange(pending.startIndex...index)
                let line = String(decoding: lineBytes, as: UTF8.self)
                return line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\0 \t"))
            }

            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                Darwin.read(fd, pointer.baseAddress!, pointer.count)
            }

            if count > 0 {
                pending.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0 && errno != EAGAIN && errno != EINTR {
                throw SerialError.readFailed(errno: errno)
            }
            if Date() > deadline {
                throw SerialError.timedOut
            }
        }
    }

    /// Sends a query and returns the device's answer.
    public func query(_ command: String) throws -> String {
        flushInput()
        try writeLine(command)
        return try readLine()
    }
}
