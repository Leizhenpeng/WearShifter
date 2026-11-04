import XCTest
@testable import WatchMouseCore

final class CapturePlanTests: XCTestCase {
    private func events(_ kind: CaptureRun.Kind, until end: TimeInterval) -> [(TimeInterval, CueSchedule.Event)] {
        var schedule = CueSchedule(kind: kind, nextInterval: { 4 })
        var result: [(TimeInterval, CueSchedule.Event)] = []
        var now = 100.0
        while now < 100 + end {
            if let event = schedule.update(now: now) { result.append((now - 100, event)) }
            now += 0.01
        }
        return result
    }

    func testCuesStartAfterLeadInThenFinishOneIntervalAfterLast() {
        let result = events(.cued(count: 2), until: 30)
        XCTAssertEqual(result.map(\.1), [.cue(index: 0), .cue(index: 1), .finished])
        XCTAssertEqual(result[0].0, 3, accuracy: 0.02)
        XCTAssertEqual(result[1].0, 7, accuracy: 0.03)
        XCTAssertEqual(result[2].0, 11, accuracy: 0.04)
    }

    func testTimedRunHasNoCues() {
        let result = events(.timed(seconds: 5), until: 20)
        XCTAssertEqual(result.map(\.1), [.finished])
        XCTAssertEqual(result[0].0, 5, accuracy: 0.02)
    }

    func testPlanCoversEveryGestureAndControl() {
        let ids = Set(CaptureRun.plan.map(\.id))
        XCTAssertEqual(ids.count, CaptureRun.plan.count)
        XCTAssertTrue(ids.isSuperset(of: ["clench_still", "double_still", "open_still", "cue_only", "move_only", "daily"]))
    }
}
