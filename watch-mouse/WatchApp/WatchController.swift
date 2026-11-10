import CoreBluetooth
import CoreMotion
import Foundation
import WatchKit
import WatchMouseCore
import simd

/// 读取手腕运动并通过蓝牙写给 Mac。
///
/// 手表不能广播蓝牙服务，所以 Mac 做外设、手表做主机。
/// 运动和蓝牙回调都在同一条串行队列上，累积器不用加锁。
final class WatchController: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isRunning = false
    @Published private(set) var linkText = "正在查找 Mac"
    @Published private(set) var detailText = ""

    private let queue = DispatchQueue(label: "watchmouse.link", qos: .userInteractive)
    private let motionQueue = OperationQueue()
    private let motion = SharedMotion.manager
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var runtimeSession: WKExtendedRuntimeSession?

    // 以下只在 queue 上访问。
    private var mapper = WristRateMapper()
    private var accumulator = MotionAccumulator()
    private var lastSampleTime: TimeInterval?
    private var samplesSinceSend = 0
    private var sentThisSecond = 0
    private var samplesThisSecond = 0
    private var blockedThisSecond = 0
    private var secondStartedAt: TimeInterval = 0
    private var searchAttempt = 0
    private var searchStartedAt: Date?

    private static let lastPeripheralKey = "lastPeripheralID"
    private static let searchRetryInterval: TimeInterval = 6

    override init() {
        super.init()
        motionQueue.underlyingQueue = queue
        motionQueue.maxConcurrentOperationCount = 1
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func toggle() {
        isRunning ? stop() : start()
        WKInterfaceDevice.current().play(isRunning ? .start : .stop)
    }

    /// 采集和光标共用一个传感器管理器，不能同时运行。
    func stopIfRunning() {
        if isRunning { stop() }
    }

    private func start() {
        guard !motion.isDeviceMotionActive else {
            detailText = "正在采集，结束后才能开始光标"
            return
        }
        guard motion.isDeviceMotionAvailable else {
            detailText = "这台手表没有运动数据"
            return
        }
        // 必须在前台启动。没有它抬腕结束后应用就被挂起，运动数据和蓝牙都会停。
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        runtimeSession = session

        let device = WKInterfaceDevice.current()
        let crownTowardHand = (device.wristLocation == .left) == (device.crownOrientation == .right)
        queue.async { [self] in
            mapper = WristRateMapper(crownTowardHand: crownTowardHand)
            accumulator = MotionAccumulator()
            lastSampleTime = nil
        }
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] sample, _ in
            guard let sample else { return }
            self?.handle(sample)
        }
        isRunning = true
    }

    private func stop() {
        motion.stopDeviceMotionUpdates()
        runtimeSession?.invalidate()
        runtimeSession = nil
        isRunning = false
    }

    private func handle(_ sample: CMDeviceMotion) {
        defer { lastSampleTime = sample.timestamp }
        samplesThisSecond += 1
        let rotation = SIMD3(sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z)
        let gravity = SIMD3(sample.gravity.x, sample.gravity.y, sample.gravity.z)
        if let lastSampleTime, let rates = mapper.rates(rotation: rotation, gravity: gravity) {
            let dt = sample.timestamp - lastSampleTime
            if dt > 0, dt < 0.1 {
                accumulator.add(yawDegrees: rates.yaw * dt, pitchDegrees: rates.pitch * dt)
            }
        }
        samplesSinceSend += 1
        if samplesSinceSend >= 2 { send(now: sample.timestamp) }
        publishStats(now: sample.timestamp)
    }

    private func send(now: TimeInterval) {
        guard let peripheral, let characteristic, peripheral.state == .connected else {
            // 没连上时不累积，否则重连瞬间光标会跳。
            accumulator = MotionAccumulator()
            samplesSinceSend = 0
            return
        }
        guard peripheral.canSendWriteWithoutResponse else {
            blockedThisSecond += 1
            return
        }
        let millis = UInt32(truncatingIfNeeded: Int64(now * 1000))
        peripheral.writeValue(accumulator.drain(timeMillis: millis).encoded(), for: characteristic, type: .withoutResponse)
        samplesSinceSend = 0
        sentThisSecond += 1
    }

    private func publishStats(now: TimeInterval) {
        guard now - secondStartedAt >= 1 else { return }
        let text = "采样 \(samplesThisSecond) Hz · 发送 \(sentThisSecond) Hz · 拥塞 \(blockedThisSecond)"
        secondStartedAt = now
        samplesThisSecond = 0
        sentThisSecond = 0
        blockedThisSecond = 0
        DispatchQueue.main.async { self.detailText = text }
    }

    /// 回到前台时重新找一次：应用被挂起后扫描会失效。
    func appBecameActive() {
        queue.async { [self] in
            if characteristic == nil { beginSearch() }
        }
    }

    /// 同时用两条路找 Mac，谁先成功算谁。
    /// 直连上次的设备不用等广播，但 Mac 的蓝牙地址会轮换，旧标识可能失效，所以还要扫描兜底。
    private func beginSearch() {
        guard central.state == .poweredOn, characteristic == nil else { return }
        if searchStartedAt == nil { searchStartedAt = Date() }
        setLink("正在查找 Mac", connected: false)
        central.scanForPeripherals(withServices: [CBUUID(string: WatchMouseBLE.serviceUUID)])
        if let known = peripheral ?? rememberedPeripheral() { attach(known) }
        watchSearch()
    }

    private func rememberedPeripheral() -> CBPeripheral? {
        guard let text = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
              let id = UUID(uuidString: text) else { return nil }
        return central.retrievePeripherals(withIdentifiers: [id]).first
    }

    private func attach(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        central.connect(target)
    }

    /// 连接请求本身不会超时，卡住时要主动取消重来，否则会一直停在查找中。
    private func watchSearch() {
        searchAttempt += 1
        let attempt = searchAttempt
        queue.asyncAfter(deadline: .now() + Self.searchRetryInterval) { [self] in
            guard attempt == searchAttempt, characteristic == nil else { return }
            if let stuck = peripheral {
                peripheral = nil
                central.cancelPeripheralConnection(stuck)
            }
            central.stopScan()
            beginSearch()
        }
    }

    private func handleLinkLost(_ lost: CBPeripheral) {
        // 换到新地址时会主动取消旧连接，那次回调不算断开。
        guard lost.identifier == peripheral?.identifier else { return }
        characteristic = nil
        accumulator = MotionAccumulator()
        beginSearch()
    }

    private func setLink(_ text: String, connected: Bool) {
        DispatchQueue.main.async {
            self.linkText = text
            self.isConnected = connected
        }
    }
}

extension WatchController: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginSearch()
        case .unauthorized:
            setLink("请在设置里允许蓝牙", connected: false)
        case .poweredOff:
            characteristic = nil
            setLink("蓝牙已关闭", connected: false)
        default:
            characteristic = nil
            setLink("蓝牙不可用", connected: false)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard found.identifier != peripheral?.identifier else { return }
        // 扫描到了不同的标识，说明 Mac 换了地址，旧的连接请求不会再成功。
        if let stale = peripheral {
            peripheral = nil
            central.cancelPeripheralConnection(stale)
        }
        attach(found)
    }

    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        central.stopScan()
        UserDefaults.standard.set(connected.identifier.uuidString, forKey: Self.lastPeripheralKey)
        connected.discoverServices([CBUUID(string: WatchMouseBLE.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        handleLinkLost(failed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral lost: CBPeripheral, error: Error?) {
        handleLinkLost(lost)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: WatchMouseBLE.motionCharacteristicUUID)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        self.characteristic = characteristic
        let elapsed = searchStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        searchStartedAt = nil
        setLink(String(format: "已连接 Mac（%.1f 秒）", elapsed), connected: true)
    }

    /// Mac 端应用重启后服务会失效，要断开重新发现。
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        characteristic = nil
        central.cancelPeripheralConnection(peripheral)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if samplesSinceSend >= 2, let lastSampleTime { send(now: lastSampleTime) }
    }
}

extension WatchController: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {}

    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        WKInterfaceDevice.current().play(.notification)
    }

    func extendedRuntimeSession(_ session: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        DispatchQueue.main.async {
            guard self.runtimeSession === session else { return }
            self.stop()
            self.detailText = "运行会话结束：\(reason.rawValue) \(error?.localizedDescription ?? "")"
        }
    }
}
