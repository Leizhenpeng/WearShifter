import Foundation
import simd

/// 把手表坐标系的角速度换算成相对地面的左右转和上下抬。
///
/// 用重力而不是固定的设备轴，手心朝下或侧立都是向右转光标就向右。
/// 右手系：+x 指向表冠一侧，+y 指向表盘 12 点，+z 垂直表盘向外。小臂沿 x 轴。
public struct WristRateMapper {
    /// 表冠朝手掌时手的方向是 +x，朝手肘时是 -x。
    public var handAxisSign: Double

    private var lastRight: SIMD3<Double>?

    public init(crownTowardHand: Bool = true) {
        handAxisSign = crownTowardHand ? 1 : -1
    }

    /// `rotation` 单位是弧度/秒，`gravity` 指向地面。返回度/秒：yaw 正值向右，pitch 正值向上。
    public mutating func rates(rotation: SIMD3<Double>, gravity: SIMD3<Double>) -> (yaw: Double, pitch: Double)? {
        guard simd_length(gravity) > 0.1 else { return nil }
        let up = -simd_normalize(gravity)
        let hand = SIMD3<Double>(handAxisSign, 0, 0)
        let horizontalHand = hand - simd_dot(hand, up) * up

        // 小臂接近竖直时水平投影没有方向，沿用上一次的右方向，光标不会突然换轴。
        let right: SIMD3<Double>
        if simd_length(horizontalHand) > 0.3 {
            right = simd_normalize(simd_cross(horizontalHand, up))
            lastRight = right
        } else if let lastRight {
            right = lastRight
        } else {
            return nil
        }

        let toDegrees = 180 / Double.pi
        return (yaw: -simd_dot(rotation, up) * toDegrees, pitch: simd_dot(rotation, right) * toDegrees)
    }
}
