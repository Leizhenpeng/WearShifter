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
        CaptureRun(id: "clench_still", title: "Clench · Still", instruction: "After the tap, count one, then make a fist once and release. Keep your arm still.", kind: .cued(count: 30)),
        CaptureRun(id: "clench_move", title: "Clench · Moving", instruction: "Slowly turn your wrist as if moving the cursor. After the tap, count one, then make a fist once.", kind: .cued(count: 20)),
        CaptureRun(id: "double_still", title: "Double Clench · Still", instruction: "After the tap, count one, then make a fist twice. Keep your arm still.", kind: .cued(count: 30)),
        CaptureRun(id: "double_move", title: "Double Clench · Moving", instruction: "Slowly turn your wrist. After the tap, count one, then make a fist twice.", kind: .cued(count: 20)),
        CaptureRun(id: "open_still", title: "Open Hand · Still", instruction: "Relax your hand. After the tap, count one, then spread your fingers and relax. Keep your arm still.", kind: .cued(count: 30)),
        CaptureRun(id: "open_move", title: "Open Hand · Moving", instruction: "Slowly turn your wrist. After the tap, count one, then spread your fingers and relax.", kind: .cued(count: 20)),
        CaptureRun(id: "cue_only", title: "Taps Only", instruction: "Keep your arm still. Don't gesture when you feel the tap.", kind: .cued(count: 30)),
        CaptureRun(id: "move_only", title: "Moving Only", instruction: "Turn your wrist as if moving the cursor. Don't make any gestures.", kind: .timed(seconds: 180)),
        CaptureRun(id: "daily", title: "Everyday Use", instruction: "Type, use the trackpad, pick things up. Don't gesture on purpose. You can end early.", kind: .timed(seconds: 1_800))
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
