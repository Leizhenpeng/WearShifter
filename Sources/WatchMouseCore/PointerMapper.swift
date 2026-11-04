import Foundation

public struct PointerDelta: Equatable {
    public var dx: Double
    public var dy: Double

    public static let zero = PointerDelta(dx: 0, dy: 0)

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

/// 把手腕转动映射成光标位移。慢转精确定位，快转跨屏。
public struct PointerMapper {
    /// 低于这个角速度（度/秒）视为静止，滤掉手抖和传感器噪声。
    public var deadzone = 2.0
    public var slowGain = 14.0
    public var fastGain = 42.0
    public var fastSpeed = 120.0
    public var sensitivity = 1.0
    public var invertX = false
    public var invertY = false
    /// 两包间隔超过它视为断流，丢弃这一包，避免恢复时光标跳变。
    public var maxGap = 0.25

    private var lastTimeMillis: UInt32?

    public init() {}

    public mutating func reset() {
        lastTimeMillis = nil
    }

    public mutating func update(_ packet: MotionPacket) -> PointerDelta {
        defer { lastTimeMillis = packet.timeMillis }
        guard let last = lastTimeMillis else { return .zero }
        let dt = Double(packet.timeMillis &- last) / 1000
        guard dt > 0, dt <= maxGap else { return .zero }
        let dx = axis(Double(packet.yawDegrees), dt: dt)
        let dy = axis(Double(packet.pitchDegrees), dt: dt)
        // 屏幕 y 轴向下，所以手抬起时 dy 为负。
        return PointerDelta(dx: invertX ? -dx : dx, dy: invertY ? dy : -dy)
    }

    private func axis(_ degrees: Double, dt: Double) -> Double {
        let speed = abs(degrees) / dt
        guard speed > deadzone else { return 0 }
        let blend = min(speed / fastSpeed, 1)
        let gain = (slowGain + (fastGain - slowGain) * blend) * sensitivity
        // 减去死区而不是直接截断，慢速时位移从零连续增长。
        return (degrees < 0 ? -1 : 1) * (speed - deadzone) * dt * gain
    }
}
