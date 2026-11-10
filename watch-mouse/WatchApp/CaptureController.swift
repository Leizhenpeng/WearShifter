#if DEBUG
import CoreMotion
import Foundation
import WatchKit
import WatchMouseCore

/// 把 100 Hz 运动数据和提示时刻写到本地，之后用 scripts/pull-captures.sh 导出。
final class CaptureController: NSObject, ObservableObject {
    @Published private(set) var activeRun: CaptureRun?
    @Published private(set) var progressText = ""
    @Published private(set) var completedCounts: [String: Int] = [:]
    @Published private(set) var errorText: String?

    private let queue = DispatchQueue(label: "watchmouse.capture", qos: .userInitiated)
    private let motionQueue = OperationQueue()
    private var runtimeSession: WKExtendedRuntimeSession?

    // 以下只在 queue 上访问。
    private var schedule: CueSchedule?
    private var samples: FileHandle?
    private var events: FileHandle?
    private var buffer = ""
    private var bufferedLines = 0
    private var lastCueIndex: Int?
    private var lastSampleTime: TimeInterval = 0
    private var startedAt: TimeInterval?

    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("captures")
    }

    override init() {
        super.init()
        motionQueue.underlyingQueue = queue
        motionQueue.maxConcurrentOperationCount = 1
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        writeDeviceInfo()
        refreshCompleted()
    }

    func start(_ run: CaptureRun) {
        let manager = SharedMotion.manager
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else {
            errorText = "Motion unavailable. Pause the cursor first."
            return
        }
        guard let files = openFiles(for: run) else {
            errorText = "Couldn't create capture files."
            return
        }
        errorText = nil
        activeRun = run
        progressText = "Get ready"
        // 要在手腕放下、屏幕熄灭后继续采集和震动。
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        runtimeSession = session

        queue.async { [self] in
            samples = files.samples
            events = files.events
            schedule = CueSchedule(kind: run.kind)
            buffer = "time,ax,ay,az,rx,ry,rz,gx,gy,gz\n"
            bufferedLines = 0
            lastCueIndex = nil
            startedAt = nil
            writeEvent("start", index: nil, time: nil)
        }
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] sample, _ in
            guard let sample else { return }
            self?.handle(sample, run: run)
        }
    }

    /// 手势没做好时点一下，分析时会排除最近一次提示。
    func markLastInvalid() {
        WKInterfaceDevice.current().play(.click)
        queue.async { [self] in
            guard let lastCueIndex else { return }
            writeEvent("invalid", index: lastCueIndex, time: lastSampleTime)
        }
    }

    func finish() {
        SharedMotion.manager.stopDeviceMotionUpdates()
        runtimeSession?.invalidate()
        runtimeSession = nil
        queue.async { [self] in
            guard schedule != nil else { return }
            schedule = nil
            writeEvent("end", index: nil, time: lastSampleTime)
            flush()
            try? samples?.close()
            try? events?.close()
            samples = nil
            events = nil
            DispatchQueue.main.async {
                self.activeRun = nil
                self.progressText = ""
                self.refreshCompleted()
            }
        }
    }

    private func handle(_ sample: CMDeviceMotion, run: CaptureRun) {
        guard var current = schedule else { return }
        let u = sample.userAcceleration, r = sample.rotationRate, g = sample.gravity
        lastSampleTime = sample.timestamp
        if startedAt == nil { startedAt = sample.timestamp }
        buffer += String(
            format: "%.4f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f\n",
            sample.timestamp, u.x, u.y, u.z, r.x, r.y, r.z, g.x, g.y, g.z
        )
        bufferedLines += 1
        if bufferedLines >= 200 { flush() }

        let event = current.update(now: sample.timestamp)
        schedule = current
        switch event {
        case let .cue(index):
            lastCueIndex = index
            writeEvent("cue", index: index, time: sample.timestamp)
            if case let .cued(count) = run.kind {
                let text = "\(index + 1) / \(count)"
                DispatchQueue.main.async {
                    self.progressText = text
                    WKInterfaceDevice.current().play(.directionUp)
                }
            }
        case .finished:
            DispatchQueue.main.async {
                WKInterfaceDevice.current().play(.success)
                self.finish()
            }
        case nil:
            if case let .timed(seconds) = run.kind, bufferedLines == 0, let startedAt {
                let left = Int(seconds - (sample.timestamp - startedAt))
                DispatchQueue.main.async { self.progressText = String(format: "%d:%02d left", left / 60, left % 60) }
            }
        }
    }

    private func flush() {
        try? samples?.write(contentsOf: Data(buffer.utf8))
        buffer = ""
        bufferedLines = 0
    }

    private func writeEvent(_ type: String, index: Int?, time: TimeInterval?) {
        let line = "\(time.map { String(format: "%.4f", $0) } ?? ""),\(type),\(index.map(String.init) ?? "")\n"
        try? events?.write(contentsOf: Data(line.utf8))
    }

    private func openFiles(for run: CaptureRun) -> (samples: FileHandle, events: FileHandle)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(run.id)--\(formatter.string(from: Date()))"
        let samplesURL = Self.directory.appendingPathComponent("\(base).samples.csv")
        let eventsURL = Self.directory.appendingPathComponent("\(base).events.csv")
        guard FileManager.default.createFile(atPath: samplesURL.path, contents: nil),
              FileManager.default.createFile(atPath: eventsURL.path, contents: Data("time,type,index\n".utf8)),
              let samples = try? FileHandle(forWritingTo: samplesURL),
              let events = try? FileHandle(forWritingTo: eventsURL) else { return nil }
        try? events.seekToEnd()
        return (samples, events)
    }

    private func refreshCompleted() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        var counts: [String: Int] = [:]
        for name in names where name.hasSuffix(".events.csv") {
            if let id = name.components(separatedBy: "--").first { counts[id, default: 0] += 1 }
        }
        completedCounts = counts
    }

    /// 佩戴方式决定坐标方向，分析时要用。启动时写一次，也能用来确认导出通路。
    private func writeDeviceInfo() {
        let device = WKInterfaceDevice.current()
        let info: [String: String] = [
            "wrist": device.wristLocation == .left ? "left" : "right",
            "crown": device.crownOrientation == .left ? "left" : "right",
            "model": device.model,
            "watchOS": device.systemVersion
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.directory.appendingPathComponent("device.json"))
        }
    }
}

extension CaptureController: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {}

    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {}

    func extendedRuntimeSession(_ session: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        DispatchQueue.main.async {
            guard self.runtimeSession === session else { return }
            self.errorText = "Session ended (\(reason.rawValue)). This run stopped."
            self.finish()
        }
    }
}
#endif
