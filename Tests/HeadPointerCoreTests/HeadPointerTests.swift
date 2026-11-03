import XCTest
@testable import HeadPointerCore

private let degree = Double.pi / 180

/// 按固定帧率生成匀速转动的样本，速度单位是度/秒。
private func samples(
    yawRate: Double = 0,
    pitchRate: Double = 0,
    duration: Double,
    startTime: Double = 0,
    startYaw: Double = 0,
    startPitch: Double = 0,
    hz: Double = 100
) -> [HeadSample] {
    (0..<Int(duration * hz)).map { index in
        let t = Double(index) / hz
        return HeadSample(
            time: startTime + t,
            yaw: startYaw + yawRate * t * degree,
            pitch: startPitch + pitchRate * t * degree
        )
    }
}

final class PointerMapperTests: XCTestCase {
    private func total(_ mapper: inout PointerMapper, _ input: [HeadSample]) -> PointerDelta {
        input.reduce(into: PointerDelta.zero) { sum, sample in
            let delta = mapper.update(sample)
            sum.dx += delta.dx
            sum.dy += delta.dy
        }
    }

    func testHeadAtRestDoesNotMoveCursor() {
        var mapper = PointerMapper()
        XCTAssertEqual(total(&mapper, samples(yawRate: 0.8, pitchRate: -0.8, duration: 1)), .zero)
    }

    func testSpeedJustAboveDeadzoneMovesVerySlightly() {
        let mapper = PointerMapper()
        let delta = mapper.delta(yawRate: -1.1, pitchRate: 0, dt: 0.02)
        XCTAssertGreaterThan(delta.dx, 0)
        XCTAssertLessThan(delta.dx, 0.1)
    }

    func testTurningRightMovesCursorRightAndLookingUpMovesCursorUp() {
        var mapper = PointerMapper()
        let delta = total(&mapper, samples(yawRate: -30, pitchRate: 30, duration: 0.5))
        XCTAssertGreaterThan(delta.dx, 0)
        XCTAssertLessThan(delta.dy, 0)
    }

    func testInvertFlipsDirection() {
        var mapper = PointerMapper()
        mapper.invertX = true
        mapper.invertY = true
        let delta = total(&mapper, samples(yawRate: -30, pitchRate: 30, duration: 0.5))
        XCTAssertLessThan(delta.dx, 0)
        XCTAssertGreaterThan(delta.dy, 0)
    }

    func testFasterTurnCoversMorePixelsPerDegree() {
        var slow = PointerMapper()
        var fast = PointerMapper()
        // 两次都转过约 30°。
        let slowDistance = abs(total(&slow, samples(yawRate: 10, duration: 3)).dx)
        let fastDistance = abs(total(&fast, samples(yawRate: 100, duration: 0.3)).dx)
        XCTAssertGreaterThan(fastDistance, slowDistance * 1.5)
    }

    func testYawWrapAroundDoesNotJump() {
        var mapper = PointerMapper()
        _ = mapper.update(HeadSample(time: 0, yaw: .pi - 0.001, pitch: 0))
        let delta = mapper.update(HeadSample(time: 0.01, yaw: -.pi + 0.001, pitch: 0))
        XCTAssertLessThan(abs(delta.dx), 20)
    }

    func testStreamGapDoesNotJump() {
        var mapper = PointerMapper()
        _ = mapper.update(HeadSample(time: 0, yaw: 0, pitch: 0))
        XCTAssertEqual(mapper.update(HeadSample(time: 2, yaw: 1, pitch: 1)), .zero)
    }
}

final class NodDetectorTests: XCTestCase {
    private func events(_ detector: inout NodDetector, _ input: [HeadSample]) -> [NodEvent] {
        input.compactMap { detector.update($0) }
    }

    /// 低头再抬头。pitch 连续，所以第二段从第一段结束的角度开始。
    private func nod(startTime: Double = 0, rate: Double = 120, phase: Double = 0.15) -> [HeadSample] {
        samples(pitchRate: -rate, duration: phase, startTime: startTime)
            + samples(pitchRate: rate, duration: phase, startTime: startTime + phase, startPitch: -rate * phase * degree)
    }

    func testQuickNodIsConfirmed() {
        var detector = NodDetector()
        XCTAssertEqual(events(&detector, nod()), [.started, .confirmed])
    }

    func testSlowLookDownDoesNotTrigger() {
        var detector = NodDetector()
        XCTAssertEqual(events(&detector, samples(pitchRate: -20, duration: 2)), [])
    }

    func testLookingDownWithoutComingBackIsCancelled() {
        var detector = NodDetector()
        let down = samples(pitchRate: -120, duration: 0.2)
        let hold = samples(duration: 0.6, startTime: 0.2, startPitch: -120 * 0.2 * degree)
        XCTAssertEqual(events(&detector, down + hold), [.started, .cancelled])
    }

    func testNodDuringFastTurnIsIgnored() {
        var detector = NodDetector()
        XCTAssertEqual(events(&detector, samples(yawRate: 150, pitchRate: -120, duration: 0.3)), [])
    }

    func testSecondNodInsideCooldownIsIgnored() {
        var detector = NodDetector()
        let input = nod() + nod(startTime: 0.3) + nod(startTime: 1.5)
        XCTAssertEqual(events(&detector, input).filter { $0 == .confirmed }.count, 2)
    }

    func testDownSignCanBeFlippedForRealDeviceData() {
        var detector = NodDetector()
        detector.downSign = 1
        let reversed = samples(pitchRate: 120, duration: 0.15)
            + samples(pitchRate: -120, duration: 0.15, startTime: 0.15, startPitch: 120 * 0.15 * degree)
        XCTAssertEqual(events(&detector, reversed), [.started, .confirmed])
    }
}
