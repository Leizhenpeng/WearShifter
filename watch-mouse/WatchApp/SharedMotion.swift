import CoreMotion

/// 苹果建议一个应用只用一个 CMMotionManager，多个实例会影响采样率。
enum SharedMotion {
    static let manager = CMMotionManager()
}
