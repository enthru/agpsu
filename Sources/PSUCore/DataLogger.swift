import Foundation

/// Appends measurement and status lines to files on disk.
///
/// The Windows version wrote into the executable's working directory. On macOS
/// that would be wherever the app happened to be launched from, so files go to
/// `~/Documents/AgilentPSU` by default and the folder is user selectable.
public final class DataLogger {
    public struct Configuration: Sendable {
        public var directory: URL
        public var model: String
        public var portName: String

        public init(directory: URL, model: String, portName: String) {
            self.directory = directory
            self.model = model
            self.portName = portName
        }
    }

    public private(set) var lastError: String?

    private var configuration: Configuration
    private var handles: [URL: FileHandle] = [:]

    public static var defaultDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return documents.appendingPathComponent("AgilentPSU", isDirectory: true)
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        closeAll()
    }

    public func update(configuration: Configuration) {
        closeAll()
        self.configuration = configuration
    }

    public var directory: URL { configuration.directory }

    public func appendOutputText(_ line: String) {
        append(line, to: fileName(suffix: "Output(date,V,A)", extension: "txt"))
    }

    public func appendOutputCSV(_ line: String) {
        append(line, to: fileName(suffix: "Output(date,V,A)", extension: "csv"))
    }

    public func appendStatus(_ line: String) {
        append(line, to: fileName(suffix: "Status", extension: "txt"))
    }

    /// `2020-09-21-HP6632B-cu.usbserial-1410-Status.txt`
    private func fileName(suffix: String, extension ext: String) -> String {
        let date = DateFormatter.fileDate.string(from: Date())
        let port = (configuration.portName as NSString).lastPathComponent
        return "\(date)-\(configuration.model)-\(port)-\(suffix).\(ext)"
    }

    private func append(_ line: String, to name: String) {
        let url = configuration.directory.appendingPathComponent(name)
        do {
            let handle = try handle(for: url)
            guard let data = (line + "\n").data(using: .utf8) else { return }
            try handle.write(contentsOf: data)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handle(for url: URL) throws -> FileHandle {
        if let existing = handles[url] { return existing }

        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handles[url] = handle
        return handle
    }

    public func closeAll() {
        for handle in handles.values {
            try? handle.close()
        }
        handles.removeAll()
    }
}
