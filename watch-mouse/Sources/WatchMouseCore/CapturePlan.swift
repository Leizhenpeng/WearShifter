import Foundation

/// 一轮采集。提示轮按震动做手势，计时轮只做规定的日常动作、不做手势。
public struct CaptureRun: Identifiable, Equatable {
    public enum Kind: Equatable {
        case cued(count: Int)
        case timed(seconds: TimeInterval)
    }

    public var id: String
    public var title: String
    public var instruction: String
    public var kind: Kind

    /// 手势轮和“只震动”轮都用同样的提示。后者提供带震动但没有手势的样本，
    /// 否则分类器可能学到“有震动就是手势”，分数会虚高。
    public static let plan: [CaptureRun] = [
        CaptureRun(id: "clench_still", title: "抓握·静止", instruction: "震动后默数一下，握拳一次再松开，手臂不动", kind: .cued(count: 30)),
        CaptureRun(id: "clench_move", title: "抓握·移动", instruction: "手腕像控制光标一样慢慢转，震动后默数一下，握拳一次", kind: .cued(count: 20)),
        CaptureRun(id: "double_still", title: "连续抓握·静止", instruction: "震动后默数一下，连续握拳两次，手臂不动", kind: .cued(count: 30)),
        CaptureRun(id: "double_move", title: "连续抓握·移动", instruction: "手腕慢慢转，震动后默数一下，连续握拳两次", kind: .cued(count: 20)),
        CaptureRun(id: "open_still", title: "张开·静止", instruction: "手自然放松，震动后默数一下，张开五指再放松，手臂不动", kind: .cued(count: 30)),
        CaptureRun(id: "open_move", title: "张开·移动", instruction: "手腕慢慢转，震动后默数一下，张开五指再放松", kind: .cued(count: 20)),
        CaptureRun(id: "cue_only", title: "只震动", instruction: "手臂不动，感到震动也不做任何手势", kind: .cued(count: 30)),
        CaptureRun(id: "move_only", title: "只移动", instruction: "像控制光标一样转手腕，不做任何手势", kind: .timed(seconds: 180)),
        CaptureRun(id: "daily", title: "日常操作", instruction: "打字、用触控板、拿东西，不刻意做手势，可以提前结束", kind: .timed(seconds: 1_800))
    ]
}

/// 决定什么时候发提示。时间用传感器时钟，提示和数据才能严格对齐。
public struct CueSchedule {
    public enum Event: Equatable {
        case cue(index: Int)
        case finished
    }

    /// 间隔随机，避免形成节奏后提前做手势。
    public static let intervalRange: ClosedRange<TimeInterval> = 3.5...4.5
    public static let leadIn: TimeInterval = 3

    private let kind: CaptureRun.Kind
    private let nextInterval: () -> TimeInterval
    private var startedAt: TimeInterval?
    private var nextCueAt: TimeInterval = 0
    private var issued = 0
    private var isFinished = false

    public init(kind: CaptureRun.Kind, nextInterval: @escaping () -> TimeInterval = { .random(in: CueSchedule.intervalRange) }) {
        self.kind = kind
        self.nextInterval = nextInterval
    }

    public mutating func update(now: TimeInterval) -> Event? {
        guard !isFinished else { return nil }
        guard let startedAt else {
            startedAt = now
            nextCueAt = now + Self.leadIn
            return nil
        }
        switch kind {
        case let .timed(seconds):
            guard now - startedAt >= seconds else { return nil }
            isFinished = true
            return .finished
        case let .cued(count):
            guard now >= nextCueAt else { return nil }
            nextCueAt = now + nextInterval()
            if issued == count {
                isFinished = true
                return .finished
            }
            issued += 1
            return .cue(index: issued - 1)
        }
    }
}
