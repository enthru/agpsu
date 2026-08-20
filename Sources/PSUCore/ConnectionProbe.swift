import Foundation

/// One-shot operations from the connection window. Each opens the port, does its
/// business and closes again, so the port stays free until the user connects.
public enum ConnectionProbe {
    /// Confirms the port can be opened at all — the equivalent of double-clicking
    /// a COM port in the Windows list to see whether it is free.
    public static func checkAvailability(path: String) throws {
        let port = SerialPort(config: SerialConfig(path: path))
        try port.open()
        port.close()
    }

    /// Full handshake: select SCPI language, read `*IDN?` and the ratings.
    public static func identify(config: SerialConfig) throws -> DeviceIdentity {
        let device = PSUDevice(config: config)
        try device.open()
        defer { device.close() }
        return try device.identify()
    }

    /// "Device Info" — reads `*IDN?` and echoes the port name on the front panel
    /// so it is obvious which of several supplies just answered.
    public static func deviceInfo(config: SerialConfig) throws -> String {
        let device = PSUDevice(config: config)
        try device.open()
        defer { device.close() }

        guard let identification = device.probeIdentification(), !identification.isEmpty else {
            throw PSUDeviceError.noResponse
        }

        try? device.send(SCPI.displayModeText)
        try? device.send(SCPI.displayText((config.path as NSString).lastPathComponent))
        return identification
    }

    /// Sends `*RST` without connecting — useful when the supply was left in a
    /// state that keeps it from answering properly.
    public static func reset(config: SerialConfig) throws {
        let device = PSUDevice(config: config)
        try device.open()
        defer { device.close() }
        try device.send(SCPI.selectSCPILanguage)
        try device.send(SCPI.reset)
    }
}
