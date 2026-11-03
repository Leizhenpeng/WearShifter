import CoreGraphics
import XCTest
@testable import HeadPointerCore

final class CursorTrackerTests: XCTestCase {
    private func step(_ tracker: inout CursorTracker, actual: CGPoint, dx: Double) -> CGPoint {
        tracker.advance(actual: actual, delta: PointerDelta(dx: dx, dy: 0), clamp: { $0 })
    }

    func testStaleReadDoesNotLoseMovement() {
        var tracker = CursorTracker()
        let first = step(&tracker, actual: CGPoint(x: 100, y: 0), dx: 10)
        // 系统还没应用上一帧，回读仍是起点，这时起点不算我们发出的目标，所以先让系统追上一帧。
        let second = step(&tracker, actual: first, dx: 10)
        let third = step(&tracker, actual: first, dx: 10)
        XCTAssertEqual(second.x, 120)
        XCTAssertEqual(third.x, 130)
    }

    func testFractionsAccumulate() {
        var tracker = CursorTracker()
        var actual = CGPoint(x: 100, y: 0)
        var target = actual
        for _ in 0..<10 {
            target = step(&tracker, actual: actual, dx: 0.3)
            // 系统把位置取整也不能丢掉小数部分。
            actual = CGPoint(x: target.x.rounded(), y: 0)
        }
        XCTAssertEqual(target.x, 103, accuracy: 1e-6)
    }

    func testTrackpadMovementResyncs() {
        var tracker = CursorTracker()
        _ = step(&tracker, actual: CGPoint(x: 100, y: 0), dx: 10)
        XCTAssertEqual(step(&tracker, actual: CGPoint(x: 500, y: 300), dx: 10), CGPoint(x: 510, y: 300))
    }

    func testClampIsRespected() {
        var tracker = CursorTracker()
        let target = tracker.advance(actual: CGPoint(x: 100, y: 0), delta: PointerDelta(dx: 50, dy: 0)) {
            CGPoint(x: min($0.x, 120), y: $0.y)
        }
        XCTAssertEqual(target.x, 120)
    }
}

final class DeltaSmootherTests: XCTestCase {
    func testDeltaIsSpreadAndConserved() {
        var smoother = DeltaSmoother()
        smoother.add(PointerDelta(dx: 12, dy: -6))
        let first = smoother.emit(elapsed: 0.005)
        XCTAssertEqual(first.dx, 3, accuracy: 1e-9)
        var sum = first
        for _ in 0..<5 {
            let delta = smoother.emit(elapsed: 0.005)
            sum.dx += delta.dx
            sum.dy += delta.dy
        }
        XCTAssertEqual(sum.dx, 12, accuracy: 1e-9)
        XCTAssertEqual(sum.dy, -6, accuracy: 1e-9)
    }

    func testNewSampleKeepsUnsentMovement() {
        var smoother = DeltaSmoother()
        smoother.add(PointerDelta(dx: 10, dy: 0))
        _ = smoother.emit(elapsed: 0.01)
        smoother.add(PointerDelta(dx: 10, dy: 0))
        XCTAssertEqual(smoother.emit(elapsed: 1).dx, 15, accuracy: 1e-9)
    }

    func testClearDropsPendingMovement() {
        var smoother = DeltaSmoother()
        smoother.add(PointerDelta(dx: 10, dy: 0))
        smoother.clear()
        XCTAssertEqual(smoother.emit(elapsed: 1), .zero)
    }
}
