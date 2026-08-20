import Foundation

/// Blocking SCPI transport for one power supply. Every call performs real serial
/// I/O, so this type must only be used from the polling worker thread — never
/// from the main actor.
public final class PSUDevice {
    private let port: SerialPort

    public var config: SerialConfig { port.config }
    public var isOpen: Bool { port.isOpen }

    public init(config: SerialConfig) {
        self.port = SerialPort(config: config)
    }

    public func open() throws {
        try port.open()
    }

    public func close() {
        port.close()
    }

    public func send(_ command: String) throws {
        try port.writeLine(command)
    }

    /// Returns the device response, or nil when the device stayed silent.
    /// The Windows original used the literal string "Null" for this case.
    public func query(_ command: String) -> String? {
        do {
            return try port.query(command)
        } catch {
            return nil
        }
    }

    public func queryNumber(_ command: String) -> Double? {
        SCPIParse.number(query(command))
    }

    /// Puts the supply into SCPI language mode and reads back its capabilities.
    ///
    /// `SYST:LANG SCPI` matters: these supplies power up in whichever language
    /// their front panel was left in, and the compatibility language does not
    /// understand the commands below.
    public func identify() throws -> DeviceIdentity {
        try send(SCPI.selectSCPILanguage)

        guard let identification = try? port.query(SCPI.identify), !identification.isEmpty else {
            throw PSUDeviceError.noResponse
        }

        guard let maxVoltage = queryNumber(SCPI.maxVoltageQuery),
              let maxCurrent = queryNumber(SCPI.maxCurrentQuery) else {
            throw PSUDeviceError.unreadable
        }

        // Not every model answers the OVP maximum; fall back to the voltage rating.
        let maxOVP = queryNumber(SCPI.maxOVPQuery) ?? maxVoltage

        try? send(SCPI.displayModeNormal)

        return DeviceIdentity(
            rawIdentification: identification,
            model: DeviceIdentity.shortModel(from: identification),
            maxVoltage: maxVoltage,
            maxCurrent: maxCurrent,
            maxOVP: maxOVP
        )
    }

    /// Asks the supply who it is without disturbing anything else — used by the
    /// "Device Info" button in the connection window.
    public func probeIdentification() -> String? {
        try? send(SCPI.selectSCPILanguage)
        return query(SCPI.identify)
    }
}

public enum PSUDeviceError: Error, LocalizedError {
    case noResponse
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .noResponse:
            return "No reply from the device. Check the null-modem adapter, the baud rate, and that the supply's RS-232 interface is enabled (INIF RS232)."
        case .unreadable:
            return "The device answered but its ratings could not be read. Make sure it is set to SCPI language mode."
        }
    }
}
