import simd
import XCTest
@testable import WatchMouseCore

final class WirePacketTests: XCTestCase {
    func testRoundTripFitsDefaultBluetoothPayload() throws {
        let packet = MotionPacket(sequence: 65_000, timeMillis: 4_000_000_000, yawDegrees: -1.25, pitchDegrees: 0.5)
        let data = packet.encoded()
        XCTAssertLessThanOrEqual(data.count, 20)
        XCTAssertEqual(MotionPacket(data: data), packet)
    }

    func testRejectsWrongLengthAndVersion() {
        XCTAssertNil(MotionPacket(data: Data([1, 2, 3])))
        var data = MotionPacket(sequence: 0, timeMillis: 0, yawDegrees: 0, pitchDegrees: 0).encoded()
        data[0] = 99
        XCTAssertNil(MotionPacket(data: data))
    }

    func testAccumulatorKeepsMotionUntilDrained() {
        var accumulator = MotionAccumulator()
        accumulator.add(yawDegrees: 1, pitchDegrees: -1)
        accumulator.add(yawDegrees: 2, pitchDegrees: -1)
        let first = accumulator.drain(timeMillis: 10)
        XCTAssertEqual(first.yawDegrees, 3)
        XCTAssertEqual(first.pitchDegrees, -2)
        let second = accumulator.drain(timeMillis: 20)
        XCTAssertEqual(second.yawDegrees, 0)
        XCTAssertEqual(second.sequence, first.sequence + 1)
    }

    func testLossCounterHandlesGapAndWraparound() {
        var counter = LossCounter()
        [65_534, 65_535, 0, 3].forEach { counter.record(UInt16($0)) }
        XCTAssertEqual(counter.received, 4)
        XCTAssertEqual(counter.lost, 2)
    }
}

final class WristRateMapperTests: XCTestCase {
    private let radians = 1.0 // 约 57.3 度/秒
    private var degrees: Double { radians * 180 / .pi }

    /// 手心朝下：+x 向前，+y 向左，+z 向上。
    func testPalmDownTurnRightAndRaise() throws {
        var mapper = WristRateMapper()
        let gravity = SIMD3<Double>(0, 0, -1)
        // 从上往下看顺时针是向右转，角速度沿 -z。
        let turn = try XCTUnwrap(mapper.rates(rotation: [0, 0, -radians], gravity: gravity))
        XCTAssertEqual(turn.yaw, degrees, accuracy: 1e-6)
        XCTAssertEqual(turn.pitch, 0, accuracy: 1e-6)
        // 抬手绕右方向（-y）正转。
        let raise = try XCTUnwrap(mapper.rates(rotation: [0, -radians, 0], gravity: gravity))
        XCTAssertEqual(raise.pitch, degrees, accuracy: 1e-6)
        XCTAssertEqual(raise.yaw, 0, accuracy: 1e-6)
    }

    /// 手掌侧立（拇指朝上）：+x 向前，+y 向上，+z 向右。结果应与手心朝下相同。
    func testPalmSidewaysGivesSameDirections() throws {
        var mapper = WristRateMapper()
        let gravity = SIMD3<Double>(0, -1, 0)
        let turn = try XCTUnwrap(mapper.rates(rotation: [0, -radians, 0], gravity: gravity))
        XCTAssertEqual(turn.yaw, degrees, accuracy: 1e-6)
        let raise = try XCTUnwrap(mapper.rates(rotation: [0, 0, radians], gravity: gravity))
        XCTAssertEqual(raise.pitch, degrees, accuracy: 1e-6)
    }

    /// 表冠朝手肘：手的方向是 -x，抬手方向要跟着反过来。
    func testCrownTowardElbowFlipsPitchAxis() throws {
        var mapper = WristRateMapper(crownTowardHand: false)
        // 手心朝下时 -x 向前，+y 向右，+z 向上。
        let raise = try XCTUnwrap(mapper.rates(rotation: [0, radians, 0], gravity: [0, 0, -1]))
        XCTAssertEqual(raise.pitch, degrees, accuracy: 1e-6)
    }

    func testForearmVerticalReusesLastAxis() throws {
        var mapper = WristRateMapper()
        XCTAssertNil(mapper.rates(rotation: [0, 0, 0], gravity: [-1, 0, 0]))
        _ = mapper.rates(rotation: [0, 0, 0], gravity: [0, 0, -1])
        let raise = try XCTUnwrap(mapper.rates(rotation: [0, -radians, 0], gravity: [-1, 0, 0]))
        XCTAssertEqual(raise.pitch, degrees, accuracy: 1e-6)
    }
}

final class PointerMapperTests: XCTestCase {
    private func packet(_ time: UInt32, yaw: Float, pitch: Float = 0) -> MotionPacket {
        MotionPacket(sequence: 0, timeMillis: time, yawDegrees: yaw, pitchDegrees: pitch)
    }

    func testFirstPacketOnlySetsClock() {
        var mapper = PointerMapper()
        XCTAssertEqual(mapper.update(packet(0, yaw: 5)), .zero)
    }

    func testDirections() {
        var mapper = PointerMapper()
        _ = mapper.update(packet(0, yaw: 0))
        let delta = mapper.update(packet(20, yaw: 1, pitch: 1))
        XCTAssertGreaterThan(delta.dx, 0)
        XCTAssertLessThan(delta.dy, 0, "抬手时光标应向上")
    }

    func testDeadzoneDropsTremor() {
        var mapper = PointerMapper()
        _ = mapper.update(packet(0, yaw: 0))
        XCTAssertEqual(mapper.update(packet(20, yaw: 0.03)).dx, 0) // 1.5 度/秒
    }

    func testGapDropsPacketInsteadOfJumping() {
        var mapper = PointerMapper()
        _ = mapper.update(packet(0, yaw: 0))
        XCTAssertEqual(mapper.update(packet(1_000, yaw: 30)), .zero)
        XCTAssertNotEqual(mapper.update(packet(1_020, yaw: 1)), .zero)
    }

    func testFasterTurnMovesFartherPerDegree() {
        var slow = PointerMapper(), fast = PointerMapper()
        _ = slow.update(packet(0, yaw: 0))
        _ = fast.update(packet(0, yaw: 0))
        let slowDelta = slow.update(packet(100, yaw: 1)).dx // 10 度/秒
        let fastDelta = fast.update(packet(10, yaw: 1)).dx // 100 度/秒
        XCTAssertGreaterThan(fastDelta, slowDelta)
    }

    func testClockWraparoundStaysContinuous() {
        var mapper = PointerMapper()
        _ = mapper.update(packet(UInt32.max - 9, yaw: 0))
        XCTAssertGreaterThan(mapper.update(packet(10, yaw: 1)).dx, 0)
    }
}
