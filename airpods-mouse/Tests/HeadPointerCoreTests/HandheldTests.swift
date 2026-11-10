import XCTest
@testable import HeadPointerCore

private let level = Vector3(x: 0, y: 0, z: -1)
/// 设备竖着拿：设备 x 轴朝上。
private let upright = Vector3(x: -1, y: 0, z: 0)

private func total(_ mapper: inout HandheldMapper, rotation: Vector3, gravity: Vector3) -> PointerDelta {
    (0..<50).reduce(into: PointerDelta.zero) { sum, index in
        let delta = mapper.update(HandheldSample(time: Double(index) * 0.02, rotation: rotation, gravity: gravity))
        sum.dx += delta.dx
        sum.dy += delta.dy
    }
}

final class HandheldMapperTests: XCTestCase {
    private func mapper() -> HandheldMapper {
        var mapper = HandheldMapper()
        mapper.forward = Vector3(x: 0, y: 1, z: 0)
        return mapper
    }

    func testLevelTurnRightMovesCursorRightOnly() {
        var mapper = mapper()
        let delta = total(&mapper, rotation: Vector3(x: 0, y: 0, z: -1), gravity: level)
        XCTAssertGreaterThan(delta.dx, 0)
        XCTAssertEqual(delta.dy, 0, accuracy: 1e-9)
    }

    func testLevelLiftMovesCursorUpOnly() {
        var mapper = mapper()
        let delta = total(&mapper, rotation: Vector3(x: 1, y: 0, z: 0), gravity: level)
        XCTAssertLessThan(delta.dy, 0)
        XCTAssertEqual(delta.dx, 0, accuracy: 1e-9)
    }

    func testUprightHoldKeepsSameScreenDirections() {
        var turn = mapper()
        let turned = total(&turn, rotation: Vector3(x: -1, y: 0, z: 0), gravity: upright)
        XCTAssertGreaterThan(turned.dx, 0)
        XCTAssertEqual(turned.dy, 0, accuracy: 1e-9)

        var lift = mapper()
        let lifted = total(&lift, rotation: Vector3(x: 0, y: 0, z: -1), gravity: upright)
        XCTAssertLessThan(lifted.dy, 0)
        XCTAssertEqual(lifted.dx, 0, accuracy: 1e-9)
    }

    func testWristRollDoesNotMoveCursor() {
        var mapper = mapper()
        XCTAssertEqual(total(&mapper, rotation: Vector3(x: 0, y: 1, z: 0), gravity: level), .zero)
    }

    func testWithoutCalibrationCursorStays() {
        var mapper = HandheldMapper()
        XCTAssertEqual(total(&mapper, rotation: Vector3(x: 1, y: 0, z: 1), gravity: level), .zero)
    }

    func testStreamGapDoesNotJump() {
        var mapper = mapper()
        let rotation = Vector3(x: 0, y: 0, z: -2)
        _ = mapper.update(HandheldSample(time: 0, rotation: rotation, gravity: level))
        XCTAssertEqual(mapper.update(HandheldSample(time: 1, rotation: rotation, gravity: level)), .zero)
    }
}

final class HandheldCalibratorTests: XCTestCase {
    private func run(_ rotationAt: (Double) -> Vector3, gravity: Vector3) -> HandheldCalibrator.State {
        var calibrator = HandheldCalibrator()
        var state = HandheldCalibrator.State.collecting
        var time = 0.0
        while state == .collecting {
            state = calibrator.update(HandheldSample(time: time, rotation: rotationAt(time), gravity: gravity))
            time += 0.02
        }
        return state
    }

    private func assertForward(_ state: HandheldCalibrator.State, _ expected: Vector3, line: UInt = #line) {
        guard case let .finished(forward) = state else {
            return XCTFail("校准没有完成：\(state)", line: line)
        }
        XCTAssertEqual(forward.x, expected.x, accuracy: 0.05, line: line)
        XCTAssertEqual(forward.y, expected.y, accuracy: 0.05, line: line)
        XCTAssertEqual(forward.z, expected.z, accuracy: 0.05, line: line)
    }

    func testLiftThenLowerFindsForwardAxis() {
        let state = run({ $0 < 0.5 ? Vector3(x: 1.5, y: 0, z: 0) : Vector3(x: -1.5, y: 0, z: 0) }, gravity: level)
        assertForward(state, Vector3(x: 0, y: 1, z: 0))
    }

    func testTurningMixedIntoGestureIsIgnored() {
        let state = run({ _ in Vector3(x: 1.5, y: 0, z: 2) }, gravity: level)
        assertForward(state, Vector3(x: 0, y: 1, z: 0))
    }

    func testUprightHoldFindsForwardAxis() {
        let state = run({ _ in Vector3(x: 0, y: 0, z: -1.5) }, gravity: upright)
        assertForward(state, Vector3(x: 0, y: 1, z: 0))
    }

    func testGestureCanStartLateAfterClick() {
        let state = run({ time in
            if time < 4 { return Vector3(x: 0, y: 0, z: 0) }
            return time < 4.5 ? Vector3(x: 1.5, y: 0, z: 0) : Vector3(x: -1.5, y: 0, z: 0)
        }, gravity: level)
        assertForward(state, Vector3(x: 0, y: 1, z: 0))
    }

    func testNoGestureFails() {
        XCTAssertEqual(run({ _ in Vector3(x: 0.01, y: 0, z: 0) }, gravity: level), .failed)
    }
}

final class FlickDetectorTests: XCTestCase {
    /// 翻出再翻回，rate 为正表示向右翻。
    private func flick(_ detector: inout FlickDetector, rate: Double, start: Double = 0, yaw: Double = 0) -> [FlickEvent] {
        (0..<20).compactMap { index -> FlickEvent? in
            let roll = index < 10 ? rate : -rate
            return detector.update(time: start + Double(index) * 0.02, yawRate: yaw, pitchRate: 0, rollRate: roll)
        }
    }

    func testRightFlick() {
        var detector = FlickDetector()
        XCTAssertEqual(flick(&detector, rate: 300), [.started, .confirmed(.right)])
    }

    func testLeftFlick() {
        var detector = FlickDetector()
        XCTAssertEqual(flick(&detector, rate: -300), [.started, .confirmed(.left)])
    }

    func testSlowRollDoesNotTrigger() {
        var detector = FlickDetector()
        XCTAssertEqual(flick(&detector, rate: 100), [])
    }

    func testRollDuringFastTurnIsIgnored() {
        var detector = FlickDetector()
        XCTAssertEqual(flick(&detector, rate: 300, yaw: 400), [])
    }

    func testRollWithoutReturnIsCancelled() {
        var detector = FlickDetector()
        let events = (0..<40).compactMap { index -> FlickEvent? in
            detector.update(time: Double(index) * 0.02, yawRate: 0, pitchRate: 0, rollRate: index == 0 ? 300 : 0)
        }
        XCTAssertEqual(events, [.started, .cancelled])
    }

    func testReturnSwingDoesNotClickAgain() {
        var detector = FlickDetector()
        let events = flick(&detector, rate: 300)
        XCTAssertEqual(events.filter { $0 == .confirmed(.right) || $0 == .confirmed(.left) }.count, 1)
    }

    func testSecondFlickAfterCooldownWorks() {
        var detector = FlickDetector()
        _ = flick(&detector, rate: 300)
        XCTAssertEqual(flick(&detector, rate: -300, start: 1.2), [.started, .confirmed(.left)])
    }
}

final class FlickCursorGateTests: XCTestCase {
    func testRollDominantMotionHoldsCursor() {
        var gate = FlickCursorGate()
        XCTAssertTrue(gate.shouldHold(time: 0, yawRate: -48, pitchRate: 55, rollRate: 275))
    }

    func testTurningWithSomeRollKeepsMoving() {
        var gate = FlickCursorGate()
        XCTAssertFalse(gate.shouldHold(time: 0, yawRate: 200, pitchRate: 0, rollRate: 100))
    }

    func testSlowRollKeepsMoving() {
        var gate = FlickCursorGate()
        XCTAssertFalse(gate.shouldHold(time: 0, yawRate: 5, pitchRate: 5, rollRate: 80))
    }

    func testHoldCoversTailThenReleases() {
        var gate = FlickCursorGate()
        _ = gate.shouldHold(time: 0, yawRate: 0, pitchRate: 0, rollRate: 300)
        XCTAssertTrue(gate.shouldHold(time: 0.05, yawRate: 30, pitchRate: 0, rollRate: 0))
        XCTAssertFalse(gate.shouldHold(time: 0.1, yawRate: 30, pitchRate: 0, rollRate: 0))
    }
}
