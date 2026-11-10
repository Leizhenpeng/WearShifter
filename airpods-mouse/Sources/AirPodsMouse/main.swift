import AppKit
import ApplicationServices
import CoreMotion
import HeadPointerCore

/// 把运动数据写成 CSV，并按秒记录运行状态，方便离线判断频率、漂移和后台表现。
final class SessionLog {
    let directory: URL
    private let motionHandle: FileHandle?
    private let statusHandle: FileHandle?
    private var buffer = ""

    init() {
        directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AirPodsMouse")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        motionHandle = SessionLog.open(directory.appendingPathComponent("motion-\(stamp).csv"))
        statusHandle = SessionLog.open(directory.appendingPathComponent("status-\(stamp).log"))
        buffer = "time,yaw,pitch,roll,rotX,rotY,rotZ,accX,accY,accZ,gravX,gravY,gravZ\n"
    }

    private static func open(_ url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    func record(_ motion: CMDeviceMotion) {
        let a = motion.attitude, r = motion.rotationRate, u = motion.userAcceleration, g = motion.gravity
        buffer += "\(motion.timestamp),\(a.yaw),\(a.pitch),\(a.roll),\(r.x),\(r.y),\(r.z),\(u.x),\(u.y),\(u.z),\(g.x),\(g.y),\(g.z)\n"
    }

    func status(_ line: String) {
        let time = ISO8601DateFormatter().string(from: Date())
        try? statusHandle?.write(contentsOf: Data("\(time) \(line)\n".utf8))
        try? motionHandle?.write(contentsOf: Data(buffer.utf8))
        buffer = ""
    }
}

/// 只负责向系统注入光标事件，需要辅助功能权限。
enum Cursor {
    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func move(to point: CGPoint, dragging: Bool) {
        post(dragging ? .leftMouseDragged : .mouseMoved, at: point)
    }

    static func click(at point: CGPoint, side: FlickSide = .left) {
        post(.mouseMoved, at: point)
        post(side == .left ? .leftMouseDown : .rightMouseDown, at: point, button: side == .left ? .left : .right)
        post(side == .left ? .leftMouseUp : .rightMouseUp, at: point, button: side == .left ? .left : .right)
    }

    static func press() {
        post(.leftMouseDown, at: location)
    }

    static func release() {
        post(.leftMouseUp, at: location)
    }

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    static func clamped(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &displays, &count)
        let bounds = displays.prefix(Int(count)).map(CGDisplayBounds).reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return point }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, CMHeadphoneMotionManagerDelegate, NSMenuDelegate {
    private let motionManager = CMHeadphoneMotionManager()
    private let log = SessionLog()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var mapper = PointerMapper()
    private var nodDetector = NodDetector()
    private var handheld = HandheldMapper()
    private var calibrator: HandheldCalibrator?
    private var flickDetector = FlickDetector()
    private var flickAnchor: CGPoint?
    private var flickGate = FlickCursorGate()
    private var cursorHeld = false
    private var tracker = CursorTracker()
    private var smoother = DeltaSmoother()
    private var smoothingEnabled = true
    private var lastFrameTime = ProcessInfo.processInfo.systemUptime
    private var dragging = false
    private var calibrationText = "未校准"
    private var nodAnchor: CGPoint?
    private var activity: NSObjectProtocol?

    /// 两个开关默认都关：先确认数据流正常，再让头部接管光标和点击。
    private var controlEnabled = false
    /// 默认手持：耳机握在手里或放在开盖的仓里。需要关闭 AirPods 的自动入耳检测才有数据。
    private var handheldMode = true
    private var nodClickEnabled = false
    private var flickClickEnabled = false
    private var leftFlicks = 0
    private var rightFlicks = 0
    private var connected = false
    private var lastError: String?
    private var sampleCount = 0
    private var currentHz = 0
    private var nodCount = 0
    private var lastMotion: CMDeviceMotion?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏应用长期不在前台，要关掉 App Nap，否则后台测试结果不可信。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "读取耳机运动数据并控制光标"
        )
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.title = "🎧 –"
        rebuildMenu()

        motionManager.delegate = self
        motionManager.startConnectionStatusUpdates()
        startMotionUpdates()

        // 全局快捷键是头部控制的离合：转到极限时先暂停、回正，再继续。
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == [.control, .option, .command] else { return }
            switch event.charactersIgnoringModifiers {
            case "p": self?.toggleControl()
            case "l": self?.startCalibration()
            case "c": self?.clickFromKeyboard(.left)
            case "r": self?.clickFromKeyboard(.right)
            case "d": self?.toggleDrag()
            default: break
            }
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        let frameTimer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.renderFrame() }
        RunLoop.main.add(frameTimer, forMode: .common)
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            lastError = "此 Mac 不支持耳机运动数据"
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            if let error {
                self?.lastError = error.localizedDescription
                return
            }
            if let motion { self?.handle(motion) }
        }
    }

    private func handle(_ motion: CMDeviceMotion) {
        lastError = nil
        lastMotion = motion
        sampleCount += 1
        log.record(motion)

        let r = motion.rotationRate, g = motion.gravity
        let handSample = HandheldSample(
            time: motion.timestamp,
            rotation: Vector3(x: r.x, y: r.y, z: r.z),
            gravity: Vector3(x: g.x, y: g.y, z: g.z)
        )
        updateCalibration(handSample)

        let sample = HeadSample(time: motion.timestamp, yaw: motion.attitude.yaw, pitch: motion.attitude.pitch)
        let headDelta = mapper.update(sample)
        // 灵敏度和反转选项都放在 mapper 上，两种模式共用。
        handheld.pointer = mapper
        let handDelta = handheld.update(handSample)
        let nod = nodDetector.update(sample)
        if nod == .confirmed { nodCount += 1 }

        // 校准动作本身不能带动光标。
        guard controlEnabled, calibrator == nil else { return }
        let delta = handheldMode ? handDelta : headDelta
        // 先判断翻腕，这一帧就能决定光标该不该动。
        if handheldMode { handleFlick(handSample) }
        if cursorHeld {
            smoother.clear()
        } else if delta != .zero {
            if smoothingEnabled { smoother.add(delta) } else { moveCursor(by: delta) }
        }
        // 手持时转动幅度大，点头检测会大量误触发，只在佩戴模式启用。
        guard nodClickEnabled, !handheldMode else { return }
        switch nod {
        case .started:
            nodAnchor = Cursor.location
        case .confirmed:
            Cursor.click(at: nodAnchor ?? Cursor.location)
            nodAnchor = nil
        case .cancelled:
            nodAnchor = nil
        case nil:
            break
        }
    }

    private func moveCursor(by delta: PointerDelta) {
        let target = tracker.advance(actual: Cursor.location, delta: delta, clamp: Cursor.clamped)
        Cursor.move(to: target, dragging: dragging)
    }

    /// 运动数据只有 50 Hz，高刷屏上光标会一格一格跳，这里把每帧位移摊到屏幕刷新上。
    private func renderFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastFrameTime
        lastFrameTime = now
        let delta = smoother.emit(elapsed: elapsed)
        guard controlEnabled, calibrator == nil, delta != .zero else { return }
        moveCursor(by: delta)
    }

    private func handleFlick(_ sample: HandheldSample) {
        guard flickClickEnabled, !dragging, let rates = handheld.rates(sample) else {
            cursorHeld = false
            return
        }
        defer {
            let gated = flickGate.shouldHold(time: sample.time, yawRate: rates.yaw, pitchRate: rates.pitch, rollRate: rates.roll)
            cursorHeld = gated || flickAnchor != nil
        }
        // 校准时抬放方向反了，前向轴也会反；此时用户会打开“反转上下”，左右翻要跟着反过来。
        let roll = mapper.invertY ? -rates.roll : rates.roll
        switch flickDetector.update(time: sample.time, yawRate: rates.yaw, pitchRate: rates.pitch, rollRate: roll) {
        case .started:
            flickAnchor = Cursor.location
        case let .confirmed(side):
            Cursor.click(at: flickAnchor ?? Cursor.location, side: side)
            flickAnchor = nil
            if side == .left { leftFlicks += 1 } else { rightFlicks += 1 }
            log.status("event=flick-\(side == .left ? "left" : "right")")
        case .cancelled:
            flickAnchor = nil
        case nil:
            break
        }
    }

    private func updateCalibration(_ sample: HandheldSample) {
        guard var current = calibrator else { return }
        let state = current.update(sample)
        calibrator = current
        switch state {
        case .collecting:
            return
        case let .finished(forward):
            handheld.forward = forward
            calibrationText = "已校准"
            log.status("event=calibrated forward=\(forward.x),\(forward.y),\(forward.z)")
            NSSound(named: "Glass")?.play()
        case .failed:
            calibrationText = "校准失败，动作要更快更大"
            log.status("event=calibration-failed")
            NSSound(named: "Basso")?.play()
        }
        calibrator = nil
        handheld.reset()
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        connected = true
        log.status("event=connected")
        startMotionUpdates()
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        connected = false
        controlEnabled = false
        mapper.reset()
        nodDetector.reset()
        handheld.reset()
        calibrator = nil
        endDrag()
        flickDetector.reset()
        log.status("event=disconnected")
    }

    private func tick() {
        currentHz = sampleCount
        sampleCount = 0
        statusItem.button?.title = calibrator != nil ? "🎧 校准中" : controlEnabled ? "🎧 ● \(currentHz)" : "🎧 \(connected ? "\(currentHz)" : "–")"
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        log.status(
            "hz=\(currentHz) connected=\(connected) auth=\(authorizationText) frontmost=\(frontmost) "
                + "mode=\(handheldMode ? "handheld" : "worn") calibrated=\(handheld.forward != nil) smooth=\(smoothingEnabled) control=\(controlEnabled) drag=\(dragging) flicks=\(leftFlicks)/\(rightFlicks) nods=\(nodCount) error=\(lastError ?? "none")"
        )
        if menu.highlightedItem == nil { rebuildMenu() }
    }

    private var authorizationText: String {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        addInfo("运动权限：\(authorizationText)")
        addInfo("耳机：\(connected ? "已连接" : "未连接")，\(currentHz) Hz")
        if let attitude = lastMotion?.attitude {
            let text = String(
                format: "偏航 %.0f°  俯仰 %.0f°  横滚 %.0f°",
                attitude.yaw * 180 / .pi, attitude.pitch * 180 / .pi, attitude.roll * 180 / .pi
            )
            addInfo(text)
        }
        addInfo("检测到点头：\(nodCount) 次")
        if let lastError { addInfo("错误：\(lastError)") }
        menu.addItem(.separator())

        addInfo("手持校准：\(calibrator != nil ? "校准中，先抬起再放下" : calibrationText)")
        addToggle("手持模式（关闭则为佩戴）", isOn: handheldMode, action: #selector(toggleHandheldMode))
        addToggle("校准手持：点后先抬起再放下（⌃⌥⌘L）", isOn: false, action: #selector(startCalibration))
        addToggle("控制光标（⌃⌥⌘P）", isOn: controlEnabled, action: #selector(toggleControl))
        addToggle("平滑移动（多约 10ms 延迟）", isOn: smoothingEnabled, action: #selector(toggleSmoothing))
        addToggle("手腕快翻点击：左翻左键，右翻右键", isOn: flickClickEnabled, action: #selector(toggleFlickClick))
        addToggle("点头点击（仅佩戴模式）", isOn: nodClickEnabled, action: #selector(toggleNodClick))
        addToggle("反转左右", isOn: mapper.invertX, action: #selector(toggleInvertX))
        addToggle("反转上下", isOn: mapper.invertY, action: #selector(toggleInvertY))

        let sensitivity = NSMenuItem(title: "灵敏度", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, value) in [("低", 0.6), ("中", 1.0), ("高", 1.6)] {
            let item = NSMenuItem(title: title, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = mapper.sensitivity == value ? .on : .off
            submenu.addItem(item)
        }
        sensitivity.submenu = submenu
        menu.addItem(sensitivity)
        menu.addItem(.separator())

        let openLogs = NSMenuItem(title: "打开日志目录", action: #selector(openLogDirectory), keyEquivalent: "")
        openLogs.target = self
        menu.addItem(openLogs)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addInfo(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addToggle(_ title: String, isOn: Bool, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        menu.addItem(item)
    }

    @objc private func toggleControl() {
        if !controlEnabled {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(options) else {
                lastError = "需要在“隐私与安全性 > 辅助功能”里允许本应用"
                return
            }
            guard !handheldMode || handheld.forward != nil else {
                calibrationText = "请先校准，再打开控制光标"
                return
            }
        }
        controlEnabled.toggle()
        smoother.clear()
        endDrag()
        flickDetector.reset()
        flickAnchor = nil
        mapper.reset()
        nodDetector.reset()
        handheld.reset()
        nodAnchor = nil
        log.status("event=control-\(controlEnabled ? "on" : "off")")
    }

    @objc private func toggleHandheldMode() {
        handheldMode.toggle()
        mapper.reset()
        handheld.reset()
        log.status("event=mode-\(handheldMode ? "handheld" : "worn")")
    }

    @objc private func startCalibration() {
        calibrator = HandheldCalibrator()
        handheld.reset()
        log.status("event=calibration-start")
    }

    private func clickFromKeyboard(_ side: FlickSide) {
        guard controlEnabled else { return }
        Cursor.click(at: Cursor.location, side: side)
    }

    private func toggleDrag() {
        guard controlEnabled else { return }
        if dragging {
            endDrag()
        } else {
            dragging = true
            Cursor.press()
            log.status("event=drag-start")
        }
    }

    /// 关闭控制或断开时必须松开，否则系统会一直认为左键按着。
    private func endDrag() {
        guard dragging else { return }
        dragging = false
        Cursor.release()
        log.status("event=drag-end")
    }

    @objc private func toggleSmoothing() {
        smoothingEnabled.toggle()
        smoother.clear()
    }

    @objc private func toggleFlickClick() {
        flickClickEnabled.toggle()
        flickDetector.reset()
        flickAnchor = nil
    }

    @objc private func toggleNodClick() {
        nodClickEnabled.toggle()
        nodAnchor = nil
    }

    @objc private func toggleInvertX() {
        mapper.invertX.toggle()
    }

    @objc private func toggleInvertY() {
        mapper.invertY.toggle()
        nodDetector.downSign = mapper.invertY ? 1 : -1
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { mapper.sensitivity = value }
    }

    @objc private func openLogDirectory() {
        NSWorkspace.shared.open(log.directory)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
