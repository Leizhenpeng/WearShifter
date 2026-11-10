import CoreGraphics
import Foundation

/// 自己记住光标的浮点位置。
/// 每帧回读系统位置的话，事件还没生效时读到的是旧值，这一帧的位移就丢了，小数部分也会丢。
public struct CursorTracker {
    /// 回读值离最近发出的目标都超过这个距离，才算用户动了触控板，要跟随系统位置。
    public var resyncDistance: CGFloat = 2

    private var position: CGPoint?
    private var recentTargets: [CGPoint] = []

    public init() {}

    public mutating func advance(actual: CGPoint, delta: PointerDelta, clamp: (CGPoint) -> CGPoint) -> CGPoint {
        let isOurs = recentTargets.contains { hypot($0.x - actual.x, $0.y - actual.y) <= resyncDistance }
        let base = isOurs ? (position ?? actual) : actual
        let target = clamp(CGPoint(x: base.x + delta.dx, y: base.y + delta.dy))
        position = target
        recentTargets.append(target)
        // 事件最多滞后几帧，留太多反而可能把触控板移动误判成自己发出的。
        if recentTargets.count > 8 { recentTargets.removeFirst() }
        return target
    }
}

/// 把一帧位移摊到下一帧到来前的时间里输出。
public struct DeltaSmoother {
    public var interval: TimeInterval = 0.02

    private var pending = PointerDelta.zero
    private var remaining: TimeInterval = 0

    public init() {}

    public mutating func add(_ delta: PointerDelta) {
        pending.dx += delta.dx
        pending.dy += delta.dy
        remaining = interval
    }

    public mutating func clear() {
        pending = .zero
        remaining = 0
    }

    public mutating func emit(elapsed: TimeInterval) -> PointerDelta {
        guard pending != .zero else { return .zero }
        let fraction = remaining > elapsed ? elapsed / remaining : 1
        let output = PointerDelta(dx: pending.dx * fraction, dy: pending.dy * fraction)
        pending.dx -= output.dx
        pending.dy -= output.dy
        remaining = max(remaining - elapsed, 0)
        return output
    }
}
