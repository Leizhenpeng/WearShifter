import Foundation

public struct Vector3: Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = Vector3(x: 0, y: 0, z: 0)

    func dot(_ other: Vector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: Vector3) -> Vector3 {
        Vector3(x: y * other.z - z * other.y, y: z * other.x - x * other.z, z: x * other.y - y * other.x)
    }

    func scaled(_ factor: Double) -> Vector3 {
        Vector3(x: x * factor, y: y * factor, z: z * factor)
    }

    func adding(_ other: Vector3) -> Vector3 {
        Vector3(x: x + other.x, y: y + other.y, z: z + other.z)
    }

    var length: Double {
        dot(self).squareRoot()
    }

    /// 接近零向量时方向没有意义，返回 nil。
    var normalized: Vector3? {
        let value = length
        return value > 1e-3 ? scaled(1 / value) : nil
    }
}

/// 手持时的一帧数据，都在设备坐标系下：rotation 单位是弧度/秒，gravity 单位是 g。
public struct HandheldSample {
    public var time: TimeInterval
    public var rotation: Vector3
    public var gravity: Vector3

    public init(time: TimeInterval, rotation: Vector3, gravity: Vector3) {
        self.time = time
        self.rotation = rotation
        self.gravity = gravity
    }
}

/// 从一次“先抬后放”的动作算出设备坐标系里的前向轴。
/// 耳机在仓里或手里的朝向事先未知，而且系统可能换一只耳机上报，所以要在运行时校准。
public struct HandheldCalibrator {
    public enum State: Equatable {
        case collecting
        case finished(forward: Vector3)
        case failed
    }

    /// 点击校准后等待动作开始的最长时间。真机上曾因动作没落在固定窗口里连续失败，所以从动作开始才计时。
    public var waitLimit: TimeInterval = 8
    /// 动作开始后继续采集的时间。
    public var duration: TimeInterval = 1.5
    /// 只采用足够快的转动（弧度/秒），避免手抖影响轴向。
    public var minimumRate = 0.7
    public var minimumSamples = 10

    private var createdAt: TimeInterval?
    private var startedAt: TimeInterval?
    private var reference: Vector3?
    private var axisSum = Vector3.zero
    private var sampleCount = 0
    private var lastUp: Vector3?

    public init() {}

    public mutating func update(_ sample: HandheldSample) -> State {
        let created = createdAt ?? sample.time
        createdAt = created

        if let up = sample.gravity.scaled(-1).normalized {
            lastUp = up
            // 只保留水平轴上的转动，这样校准动作里混入的左右转动不会带偏结果。
            let horizontal = sample.rotation.adding(up.scaled(-sample.rotation.dot(up)))
            if horizontal.length >= minimumRate {
                // 第一次够快的转动被约定为“抬起”，放下时方向相反，翻转后累加。
                startedAt = startedAt ?? sample.time
                let reference = reference ?? horizontal
                self.reference = reference
                axisSum = axisSum.adding(horizontal.dot(reference) >= 0 ? horizontal : horizontal.scaled(-1))
                sampleCount += 1
            }
        }

        guard let start = startedAt else {
            return sample.time - created >= waitLimit ? .failed : .collecting
        }
        guard sample.time - start >= duration else { return .collecting }
        guard sampleCount >= minimumSamples, let up = lastUp, let right = axisSum.normalized,
              let forward = up.cross(right).normalized
        else { return .failed }
        return .finished(forward: forward)
    }
}

/// 把手持设备的转动映射成光标位移。
/// 水平方向取绕重力轴的转动，垂直方向取绕“前向轴与重力轴的叉积”的转动，手腕横滚不移动光标。
public struct HandheldMapper {
    public var pointer = PointerMapper()
    public var forward: Vector3?

    private var previousTime: TimeInterval?

    public init() {}

    public mutating func reset() {
        previousTime = nil
    }

    public mutating func update(_ sample: HandheldSample) -> PointerDelta {
        defer { previousTime = sample.time }
        guard let previousTime else { return .zero }
        let dt = sample.time - previousTime
        guard dt > 0, dt <= 0.1 else { return .zero }

        guard let rates = rates(sample) else { return .zero }
        return pointer.delta(yawRate: rates.yaw, pitchRate: rates.pitch, dt: dt)
    }
}

extension HandheldMapper {
    /// 手持坐标系下的角速度（度/秒），校准前返回 nil。
    public func rates(_ sample: HandheldSample) -> (yaw: Double, pitch: Double, roll: Double)? {
        guard let forward, let up = sample.gravity.scaled(-1).normalized else { return nil }
        let toDegrees = 180 / Double.pi
        // 前向轴几乎竖直时没有确定的右向轴，这一帧不产生垂直转动。
        let pitch = forward.cross(up).normalized.map { sample.rotation.dot($0) * toDegrees } ?? 0
        return (sample.rotation.dot(up) * toDegrees, pitch, sample.rotation.dot(forward) * toDegrees)
    }
}

public enum FlickSide: Equatable {
    case left
    case right
}

public enum FlickEvent: Equatable {
    /// 开始翻腕，调用方应记下光标位置，确认后点在这里。
    case started
    case confirmed(FlickSide)
    case cancelled
}

/// 检测一次手腕快翻：快速翻出再在时间窗内翻回，方向由翻出的方向决定。
/// 绕前向轴右手定则的正方向是向右翻。
public struct FlickDetector {
    public var threshold = 180.0
    public var returnThreshold = 90.0
    /// 横滚要明显大于其他轴，否则属于移动光标时带出来的转动。
    public var dominance = 1.5
    public var window: TimeInterval = 0.4
    public var cooldown: TimeInterval = 0.5

    private var startedAt: TimeInterval?
    private var side = FlickSide.left
    private var lastEventAt = -TimeInterval.infinity

    public init() {}

    public mutating func reset() {
        startedAt = nil
    }

    public mutating func update(time: TimeInterval, yawRate: Double, pitchRate: Double, rollRate: Double) -> FlickEvent? {
        if let start = startedAt {
            if time - start > window {
                startedAt = nil
                lastEventAt = time
                return .cancelled
            }
            let returning = side == .right ? rollRate < -returnThreshold : rollRate > returnThreshold
            guard returning else { return nil }
            startedAt = nil
            lastEventAt = time
            return .confirmed(side)
        }

        guard time - lastEventAt >= cooldown, abs(rollRate) > threshold,
              abs(rollRate) > max(abs(yawRate), abs(pitchRate)) * dominance
        else { return nil }
        startedAt = time
        side = rollRate > 0 ? .right : .left
        return .started
    }
}

/// 判断光标是否该暂停：转动以横滚为主时属于翻腕，不能带动光标。
/// 从翻腕刚起势就暂停，并多停一小段，盖住翻回时的尾巴。
public struct FlickCursorGate {
    /// 真机录制回放：60°/s、1.2 倍会误伤约 16% 的正常移动，这组降到约 8%，翻腕残余偏移中位数约 22px。
    public var minimumRoll = 90.0
    public var dominance = 1.5
    public var hold: TimeInterval = 0.08

    private var heldUntil = -TimeInterval.infinity

    public init() {}

    public mutating func shouldHold(time: TimeInterval, yawRate: Double, pitchRate: Double, rollRate: Double) -> Bool {
        if abs(rollRate) > minimumRoll, abs(rollRate) > max(abs(yawRate), abs(pitchRate)) * dominance {
            heldUntil = time + hold
        }
        return time < heldUntil
    }
}
