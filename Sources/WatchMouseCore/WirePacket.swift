import Foundation

public enum WatchMouseBLE {
    public static let serviceUUID = "6E0F6A10-5B1C-4C7E-9B57-3A6C2D8F1A01"
    public static let motionCharacteristicUUID = "6E0F6A11-5B1C-4C7E-9B57-3A6C2D8F1A01"
}

/// 一段时间内累积的手腕转动。发的是角度增量而不是角速度，发送被蓝牙拥塞推迟时位移不会丢。
public struct MotionPacket: Equatable {
    public static let version: UInt8 = 1
    public static let byteCount = 15

    public var sequence: UInt16
    /// 手表开机以来的毫秒数，只用来算相邻两包的间隔。
    public var timeMillis: UInt32
    /// 正值表示手向右转。
    public var yawDegrees: Float
    /// 正值表示手向上抬。
    public var pitchDegrees: Float

    public init(sequence: UInt16, timeMillis: UInt32, yawDegrees: Float, pitchDegrees: Float) {
        self.sequence = sequence
        self.timeMillis = timeMillis
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.byteCount)
        data.append(Self.version)
        Self.append(sequence, to: &data)
        Self.append(timeMillis, to: &data)
        Self.append(yawDegrees.bitPattern, to: &data)
        Self.append(pitchDegrees.bitPattern, to: &data)
        return data
    }

    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.byteCount, bytes[0] == Self.version else { return nil }
        sequence = UInt16(Self.read(bytes, at: 1, count: 2))
        timeMillis = Self.read(bytes, at: 3, count: 4)
        yawDegrees = Float(bitPattern: Self.read(bytes, at: 7, count: 4))
        pitchDegrees = Float(bitPattern: Self.read(bytes, at: 11, count: 4))
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func read(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt32 {
        (0..<count).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
    }
}

/// 累积两次发送之间的转动，发送成功才清零。
public struct MotionAccumulator {
    private var yaw = 0.0
    private var pitch = 0.0
    private var sequence: UInt16 = 0

    public init() {}

    public mutating func add(yawDegrees: Double, pitchDegrees: Double) {
        yaw += yawDegrees
        pitch += pitchDegrees
    }

    public mutating func drain(timeMillis: UInt32) -> MotionPacket {
        defer {
            yaw = 0
            pitch = 0
            sequence &+= 1
        }
        return MotionPacket(sequence: sequence, timeMillis: timeMillis, yawDegrees: Float(yaw), pitchDegrees: Float(pitch))
    }
}

/// 统计丢包。序号回绕时用无符号差值，乱序或重连造成的大跳变不算丢包。
public struct LossCounter {
    public private(set) var received = 0
    public private(set) var lost = 0
    private var last: UInt16?

    public init() {}

    public mutating func record(_ sequence: UInt16) {
        received += 1
        defer { last = sequence }
        guard let last else { return }
        let gap = Int(sequence &- last)
        if gap > 1, gap < 1_000 { lost += gap - 1 }
    }
}
