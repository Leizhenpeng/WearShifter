import AppKit
import ApplicationServices
import CoreBluetooth
import WatchMouseCore

/// 记录每个收到的包和每秒状态，用来离线判断频率、丢包和断流。
final class SessionLog {
    let directory: URL
    private let packets: FileHandle?
    private let status: FileHandle?
    private var buffer = "arrivalUptime,sequence,watchMillis,yawDegrees,pitchDegrees\n"

    init() {
        directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WatchMouse")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        packets = SessionLog.open(directory.appendingPathComponent("packets-\(stamp).csv"))
        status = SessionLog.open(directory.appendingPathComponent("status-\(stamp).log"))
    }

    private static func open(_ url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    func record(_ packet: MotionPacket, arrival: TimeInterval) {
        buffer += "\(arrival),\(packet.sequence),\(packet.timeMillis),\(packet.yawDegrees),\(packet.pitchDegrees)\n"
    }

    func status(_ line: String) {
        let time = ISO8601DateFormatter().string(from: Date())
        try? status?.write(contentsOf: Data("\(time) \(line)\n".utf8))
        try? packets?.write(contentsOf: Data(buffer.utf8))
        buffer = ""
    }
}

/// 只负责向系统注入光标事件，需要辅助功能权限。
enum Cursor {
    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func move(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, CBPeripheralManagerDelegate {
    private let log = SessionLog()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var peripheral: CBPeripheralManager!
    private var activity: NSObjectProtocol?

    private var mapper = PointerMapper()
    private var tracker = CursorTracker()
    private var smoother = DeltaSmoother()
    private var loss = LossCounter()

    /// 默认关闭：先确认数据流正常，再让手腕接管光标。
    private var controlEnabled = false
    private var bluetoothText = "蓝牙启动中"
    private var lastError: String?
    private var lastPacketAt: TimeInterval?
    private var packetsThisSecond = 0
    private var currentHz = 0
    private var maxGapThisSecond = 0.0
    private var currentMaxGap = 0.0
    private var latencyRequested = Set<UUID>()
    private var lastFrameTime = ProcessInfo.processInfo.systemUptime

    private var connected: Bool {
        guard let lastPacketAt else { return false }
        return ProcessInfo.processInfo.systemUptime - lastPacketAt < 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏应用长期不在前台，要关掉 App Nap，否则光标会卡顿。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "接收手表运动数据并控制光标"
        )
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        updateTitle()

        peripheral = CBPeripheralManager(delegate: self, queue: .main)

        // 全局快捷键是离合：手转到极限时先暂停、回正，再继续；光标失控时也靠它停下。
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == [.control, .option, .command], event.charactersIgnoringModifiers == "p" else { return }
            self?.toggleControl()
        }

        let frameTimer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.renderFrame() }
        RunLoop.main.add(frameTimer, forMode: .common)
        let statusTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(statusTimer, forMode: .common)
    }

    // MARK: 蓝牙

    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        log.status("event=bluetooth-state value=\(manager.state.rawValue)")
        switch manager.state {
        case .poweredOn:
            let characteristic = CBMutableCharacteristic(
                type: CBUUID(string: WatchMouseBLE.motionCharacteristicUUID),
                properties: [.writeWithoutResponse],
                value: nil,
                permissions: [.writeable]
            )
            let service = CBMutableService(type: CBUUID(string: WatchMouseBLE.serviceUUID), primary: true)
            service.characteristics = [characteristic]
            manager.removeAllServices()
            manager.add(service)
        case .unauthorized:
            bluetoothText = "需要在“隐私与安全性 > 蓝牙”里允许本应用"
        case .poweredOff:
            bluetoothText = "蓝牙已关闭"
        default:
            bluetoothText = "蓝牙不可用"
        }
        updateTitle()
    }

    func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            bluetoothText = "添加服务失败：\(error.localizedDescription)"
            return
        }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: WatchMouseBLE.serviceUUID)],
            CBAdvertisementDataLocalNameKey: "WatchMouse"
        ])
    }

    func peripheralManagerDidStartAdvertising(_ manager: CBPeripheralManager, error: Error?) {
        bluetoothText = error.map { "广播失败：\($0.localizedDescription)" } ?? "等待手表连接"
        log.status("event=advertising error=\(error?.localizedDescription ?? "none")")
    }

    func peripheralManager(_ manager: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if latencyRequested.insert(request.central.identifier).inserted {
                manager.setDesiredConnectionLatency(.low, for: request.central)
                log.status("event=central central=\(request.central.identifier) mtu=\(request.central.maximumUpdateValueLength)")
            }
            if let data = request.value, let packet = MotionPacket(data: data) {
                receive(packet)
            }
        }
    }

    private func receive(_ packet: MotionPacket) {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastPacketAt { maxGapThisSecond = max(maxGapThisSecond, now - lastPacketAt) }
        lastPacketAt = now
        packetsThisSecond += 1
        loss.record(packet.sequence)
        log.record(packet, arrival: now)
        let delta = mapper.update(packet)
        if controlEnabled { smoother.add(delta) }
    }

    // MARK: 光标

    /// 蓝牙包约 50 Hz，高刷屏上光标会一格一格跳，这里把每包位移摊到屏幕刷新上。
    private func renderFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastFrameTime
        lastFrameTime = now
        let delta = smoother.emit(elapsed: elapsed)
        guard controlEnabled, delta != .zero else { return }
        Cursor.move(to: tracker.advance(actual: Cursor.location, delta: delta, clamp: Cursor.clamped))
    }

    private func tick() {
        currentHz = packetsThisSecond
        currentMaxGap = maxGapThisSecond
        packetsThisSecond = 0
        maxGapThisSecond = 0
        if !connected {
            smoother.clear()
            mapper.reset()
        }
        updateTitle()
        log.status(
            "hz=\(currentHz) received=\(loss.received) lost=\(loss.lost) maxGapMs=\(Int(currentMaxGap * 1000)) " +
            "control=\(controlEnabled) sensitivity=\(mapper.sensitivity)"
        )
    }

    // MARK: 菜单

    private func updateTitle() {
        statusItem.button?.title = connected ? "⌚️ \(currentHz)Hz\(controlEnabled ? " ●" : "")" : "⌚️ –"
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        addInfo(connected ? "已连接 \(currentHz) Hz，最大间隔 \(Int(currentMaxGap * 1000)) ms" : bluetoothText)
        addInfo("累计收到 \(loss.received) 包，丢失 \(loss.lost) 包")
        if let lastError { addInfo(lastError) }
        menu.addItem(.separator())
        addToggle("控制光标（⌃⌥⌘P）", isOn: controlEnabled, action: #selector(toggleControl))
        addToggle("反转左右", isOn: mapper.invertX, action: #selector(toggleInvertX))
        addToggle("反转上下", isOn: mapper.invertY, action: #selector(toggleInvertY))
        let sensitivityMenu = NSMenu()
        for value in [0.5, 0.75, 1.0, 1.5, 2.0] {
            let item = NSMenuItem(title: "\(value)", action: #selector(setSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = mapper.sensitivity == value ? .on : .off
            sensitivityMenu.addItem(item)
        }
        let sensitivityItem = NSMenuItem(title: "灵敏度", action: nil, keyEquivalent: "")
        sensitivityItem.submenu = sensitivityMenu
        menu.addItem(sensitivityItem)
        menu.addItem(.separator())
        addToggle("打开日志目录", isOn: false, action: #selector(openLogDirectory))
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
        }
        lastError = nil
        controlEnabled.toggle()
        smoother.clear()
        updateTitle()
        log.status("event=control-\(controlEnabled ? "on" : "off")")
    }

    @objc private func toggleInvertX() {
        mapper.invertX.toggle()
    }

    @objc private func toggleInvertY() {
        mapper.invertY.toggle()
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
