import XCTest
@testable import PSUCore

final class SampleBufferTests: XCTestCase {

    func testDropsOldestSamplesBeyondCapacity() {
        var buffer = SampleBuffer(capacity: 10)
        for value in 0..<25 {
            buffer.append(value: Double(value), at: Date())
        }
        XCTAssertEqual(buffer.samples.count, 10)
        XCTAssertEqual(buffer.totalRecorded, 25)
        XCTAssertEqual(buffer.samples.first?.value, 15)
        XCTAssertEqual(buffer.minimum, 0, "extremes are recorded over the whole run, not just the retained window")
        XCTAssertEqual(buffer.maximum, 24)
    }

    func testDecimationPreservesSpikes() {
        var buffer = SampleBuffer(capacity: 100_000)
        for index in 0..<20_000 {
            buffer.append(value: index == 12_345 ? 999 : 1, at: Date())
        }
        let reduced = buffer.decimated(into: 500)
        XCTAssertLessThanOrEqual(reduced.count, 520)
        XCTAssertTrue(reduced.contains { $0.value == 999 }, "a single-sample spike must survive decimation")
    }

    func testDecimationKeepsChronologicalOrder() {
        var buffer = SampleBuffer(capacity: 10_000)
        for index in 0..<5_000 {
            buffer.append(value: sin(Double(index) / 50), at: Date())
        }
        let reduced = buffer.decimated(into: 400)
        XCTAssertEqual(reduced, reduced.sorted { $0.index < $1.index })
    }

    func testShortSeriesIsReturnedUntouched() {
        var buffer = SampleBuffer(capacity: 1000)
        for index in 0..<50 { buffer.append(value: Double(index), at: Date()) }
        XCTAssertEqual(buffer.decimated(into: 1200).count, 50)
    }
}
