import Foundation

public struct PSUSample: Identifiable, Sendable, Equatable {
    public let index: Int
    public let timestamp: Date
    public let value: Double

    public var id: Int { index }

    public init(index: Int, timestamp: Date, value: Double) {
        self.index = index
        self.timestamp = timestamp
        self.value = value
    }
}

/// Fixed-capacity sample history for one graph.
///
/// The Windows version let the user choose 50K … 2M samples per graph. Keeping
/// that many points is fine for logging and export, but handing them all to a
/// chart is not — `decimated(into:)` reduces the series to a drawable number of
/// points while preserving every local minimum and maximum, so spikes survive.
public struct SampleBuffer: Sendable {
    public private(set) var samples: [PSUSample] = []
    public private(set) var totalRecorded: Int = 0
    public private(set) var negativeCount: Int = 0
    public private(set) var minimum: Double?
    public private(set) var maximum: Double?

    public var capacity: Int {
        didSet {
            trim()
        }
    }

    public static let capacityChoices = [50_000, 100_000, 200_000, 500_000, 1_000_000, 2_000_000]

    public init(capacity: Int = 50_000) {
        self.capacity = capacity
        samples.reserveCapacity(min(capacity, 4096))
    }

    public var isEmpty: Bool { samples.isEmpty }
    public var latest: PSUSample? { samples.last }

    public mutating func append(value: Double, at timestamp: Date) {
        samples.append(PSUSample(index: totalRecorded, timestamp: timestamp, value: value))
        totalRecorded += 1
        if value < 0 { negativeCount += 1 }
        minimum = min(minimum ?? value, value)
        maximum = max(maximum ?? value, value)
        trim()
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        totalRecorded = 0
        negativeCount = 0
        minimum = nil
        maximum = nil
    }

    private mutating func trim() {
        let overflow = samples.count - capacity
        if overflow > 0 {
            samples.removeFirst(overflow)
        }
    }

    /// Min/max preserving decimation down to roughly `target` points.
    public func decimated(into target: Int = 1200) -> [PSUSample] {
        guard target > 2, samples.count > target else { return samples }

        let bucketSize = Int((Double(samples.count) / Double(target / 2)).rounded(.up))
        var output: [PSUSample] = []
        output.reserveCapacity(target + 2)

        var start = 0
        while start < samples.count {
            let end = min(start + bucketSize, samples.count)
            let bucket = samples[start..<end]
            guard let lowest = bucket.min(by: { $0.value < $1.value }),
                  let highest = bucket.max(by: { $0.value < $1.value }) else {
                start = end
                continue
            }
            // Emit in chronological order so the line does not zig-zag backwards.
            if lowest.index <= highest.index {
                output.append(lowest)
                if highest.index != lowest.index { output.append(highest) }
            } else {
                output.append(highest)
                output.append(lowest)
            }
            start = end
        }
        return output
    }

    /// CSV body for "Save Graph Data".
    public func csv(valueHeader: String) -> String {
        var text = "Sample,DateTime,\(valueHeader)\n"
        let formatter = DateFormatter.logTimestamp
        for sample in samples {
            text += "\(sample.index),\(formatter.string(from: sample.timestamp)),\(sample.value)\n"
        }
        return text
    }
}

extension DateFormatter {
    /// `2020/09/21 06:42:29` — the machine readable stamp used in CSV output.
    public static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    /// `6:42:29 AM` — the stamp appended to every event-list entry.
    public static let eventTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm:ss a"
        return formatter
    }()

    /// `2020/09/21 6:42:29 AM` — the stamp used in the plain-text output log.
    public static let textLogTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd h:mm:ss a"
        return formatter
    }()

    /// `2020-09-21` — the date that goes into log file names.
    public static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
