import Foundation

/// 一帧头部姿态，角度单位是弧度。
public struct HeadSample {
    public var time: TimeInterval
    public var yaw: Double
    public var pitch: Double

    public init(time: TimeInterval, yaw: Double, pitch: Double) {
        self.time = time
        self.yaw = yaw
        self.pitch = pitch
    }
}

public struct PointerDelta: Equatable {
    public var dx: Double
    public var dy: Double

    public static let zero = PointerDelta(dx: 0, dy: 0)
}

/// 相邻两帧的角速度（度/秒）。间隔异常时返回 nil，避免断流恢复后光标跳变。
struct AngularRate {
    var yaw: Double
    var pitch: Double

    init?(from previous: HeadSample, to current: HeadSample, maxGap: TimeInterval = 0.1) {
        let dt = current.time - previous.time
        guard dt > 0, dt <= maxGap else { return nil }
        yaw = wrappedDegrees(current.yaw - previous.yaw) / dt
        pitch = wrappedDegrees(current.pitch - previous.pitch) / dt
    }
}

/// 把弧度差折算到 -180°...180°，跨过 ±π 时不会出现一整圈的假跳变。
func wrappedDegrees(_ radians: Double) -> Double {
    atan2(sin(radians), cos(radians)) * 180 / .pi
}

/// 把头部转动映射成光标位移。只用相邻帧的相对变化，姿态的长期漂移不会累积到光标上。
public struct PointerMapper {
    /// 低于这个角速度视为头部静止，用来滤掉呼吸和传感器抖动。
    public var deadzone = 1.0
    /// 慢速转头时每度移动的像素，保证能精确定位。
    public var slowGain = 14.0
    /// 快速转头时每度移动的像素，保证不用大幅转头也能跨屏。
    public var fastGain = 42.0
    /// 达到 fastGain 的角速度（度/秒）。
    public var fastSpeed = 120.0
    public var sensitivity = 1.0
    public var invertX = false
    public var invertY = false

    private var previous: HeadSample?

    public init() {}

    public mutating func reset() {
        previous = nil
    }

    public mutating func update(_ sample: HeadSample) -> PointerDelta {
        defer { previous = sample }
        guard let previous, let rate = AngularRate(from: previous, to: sample) else { return .zero }
        return delta(yawRate: rate.yaw, pitchRate: rate.pitch, dt: sample.time - previous.time)
    }

    /// 角速度单位是度/秒。右手系下向右转 yaw 减小、抬起 pitch 增大，而屏幕坐标的 y 轴向下，所以默认都取反。
    public func delta(yawRate: Double, pitchRate: Double, dt: Double) -> PointerDelta {
        let dx = axisDelta(yawRate, dt: dt) * (invertX ? 1 : -1)
        let dy = axisDelta(pitchRate, dt: dt) * (invertY ? 1 : -1)
        return PointerDelta(dx: dx, dy: dy)
    }

    private func axisDelta(_ rate: Double, dt: Double) -> Double {
        let speed = abs(rate)
        guard speed > deadzone else { return 0 }
        let blend = min(speed / fastSpeed, 1)
        let gain = (slowGain + (fastGain - slowGain) * blend) * sensitivity
        // 减去死区而不是直接截断，慢速时位移从零连续增长，不会过了门槛突然一跳。
        let direction: Double = rate < 0 ? -1 : 1
        return direction * (speed - deadzone) * dt * gain
    }
}

public enum NodEvent: Equatable {
    /// 开始低头，调用方应记下光标位置，确认后点在这里，而不是点头带偏后的位置。
    case started
    case confirmed
    case cancelled
}

/// 检测一次点头：先快速低头，再在时间窗内快速抬头。慢慢低头看屏幕不会触发。
public struct NodDetector {
    /// 低头时 pitch 的变化方向。AirPods 的实际方向以真机数据为准。
    public var downSign = -1.0
    public var threshold = 60.0
    public var window: TimeInterval = 0.5
    public var cooldown: TimeInterval = 0.8

    private var previous: HeadSample?
    private var startedAt: TimeInterval?
    private var lastConfirmedAt = -TimeInterval.infinity

    public init() {}

    public mutating func reset() {
        previous = nil
        startedAt = nil
    }

    public mutating func update(_ sample: HeadSample) -> NodEvent? {
        defer { previous = sample }
        guard let previous, let rate = AngularRate(from: previous, to: sample) else {
            guard startedAt != nil else { return nil }
            startedAt = nil
            return .cancelled
        }
        let downRate = rate.pitch * downSign

        if let start = startedAt {
            if sample.time - start > window {
                startedAt = nil
                return .cancelled
            }
            if downRate < -threshold {
                startedAt = nil
                lastConfirmedAt = sample.time
                return .confirmed
            }
            return nil
        }

        let isCoolingDown = sample.time - lastConfirmedAt < cooldown
        // 同时大幅转头属于移动光标，不算点头。
        if !isCoolingDown, downRate > threshold, abs(rate.yaw) < threshold {
            startedAt = sample.time
            return .started
        }
        return nil
    }
}
