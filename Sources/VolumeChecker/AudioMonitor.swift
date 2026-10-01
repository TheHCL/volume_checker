import Accelerate
import AppKit
import AudioToolbox
import AVFoundation
import Combine
import UserNotifications

struct LevelSample: Identifiable {
    let id = UUID()
    let date: Date
    let db: Double
}

/// 音量連續超過門檻一段時間就算一次「吵雜事件」。
struct NoiseEvent: Identifiable {
    let id = UUID()
    let start: Date
    var end: Date
    var peak: Double
    var energySum: Double
    var sampleCount: Int
    var isOngoing = true

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var leq: Double { sampleCount > 0 ? 10 * log10(energySum / Double(sampleCount)) : peak }
}

/// 從麥克風讀取音訊、計算音量、偵測吵雜事件並發出提醒。
final class AudioMonitor: ObservableObject {
    // MARK: - 狀態

    /// 音訊引擎實際正在收音。
    @Published private(set) var isRunning = false
    /// 使用者按了「開始」；若麥克風被拔掉，重新插上時會自動恢復。
    @Published private(set) var wantsRunning = false
    @Published private(set) var currentDB = 0.0
    @Published private(set) var history: [LevelSample] = []
    @Published private(set) var events: [NoiseEvent] = []
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var isNoisy = false
    @Published private(set) var startedAt: Date?
    @Published var errorMessage: String?

    private(set) var sessionMax = 0.0
    private var sessionEnergy = 0.0
    private var sessionSamples = 0
    private var sessionOverSamples = 0

    var sessionLeq: Double {
        sessionSamples > 0 ? 10 * log10(sessionEnergy / Double(sessionSamples)) : 0
    }

    var percentOverThreshold: Double {
        sessionSamples > 0 ? Double(sessionOverSamples) / Double(sessionSamples) * 100 : 0
    }

    // MARK: - 設定（自動存到 UserDefaults）

    /// 空字串代表「系統預設輸入裝置」。
    @Published var selectedDeviceUID: String {
        didSet {
            defaults.set(selectedDeviceUID, forKey: Keys.device)
            if isRunning || wantsRunning { restart() }
        }
    }
    @Published var threshold: Double { didSet { defaults.set(threshold, forKey: Keys.threshold) } }
    /// 超過門檻持續幾秒才算吵雜事件（避免一聲喇叭就觸發）。
    @Published var minDuration: Double { didSet { defaults.set(minDuration, forKey: Keys.minDuration) } }
    /// dBFS 轉換成近似 dB SPL 的校正值，可用手機分貝計 App 對照調整。
    @Published var calibrationOffset: Double { didSet { defaults.set(calibrationOffset, forKey: Keys.calibration) } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) } }
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Keys.sound) } }
    @Published var loggingEnabled: Bool {
        didSet {
            defaults.set(loggingEnabled, forKey: Keys.logging)
            if !loggingEnabled { logger.flush() }
        }
    }
    @Published var preventSleep: Bool {
        didSet {
            defaults.set(preventSleep, forKey: Keys.preventSleep)
            if isRunning { beginActivity() }
        }
    }

    let logger = LevelLogger()

    // MARK: - 私有

    private enum Keys {
        static let device = "selectedDeviceUID"
        static let threshold = "threshold"
        static let minDuration = "minDuration"
        static let calibration = "calibrationOffset"
        static let notifications = "notificationsEnabled"
        static let sound = "soundEnabled"
        static let logging = "loggingEnabled"
        static let preventSleep = "preventSleep"
    }

    private let defaults = UserDefaults.standard
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?

    private let historyBinSeconds = 0.5
    private let historyLength = 600 // 0.5 秒 × 600 = 最近 5 分鐘
    private var binStart = Date()
    private var binEnergy = 0.0
    private var binSamples = 0

    /// 音量低於門檻多久才視為事件結束。
    private let releaseSeconds = 2.0
    /// 兩次提醒之間至少間隔幾秒，避免連續轟炸。
    private let alertCooldown = 60.0
    private var overStart: Date?
    private var lastAbove: Date?
    private var lastAlert: Date?

    static let canUseNotifications = Bundle.main.bundleIdentifier != nil

    init() {
        defaults.register(defaults: [
            Keys.device: "",
            Keys.threshold: 65.0,
            Keys.minDuration: 3.0,
            Keys.calibration: 100.0,
            Keys.notifications: true,
            Keys.sound: false,
            Keys.logging: true,
            Keys.preventSleep: true,
        ])
        selectedDeviceUID = defaults.string(forKey: Keys.device) ?? ""
        threshold = defaults.double(forKey: Keys.threshold)
        minDuration = defaults.double(forKey: Keys.minDuration)
        calibrationOffset = defaults.double(forKey: Keys.calibration)
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)
        soundEnabled = defaults.bool(forKey: Keys.sound)
        loggingEnabled = defaults.bool(forKey: Keys.logging)
        preventSleep = defaults.bool(forKey: Keys.preventSleep)

        refreshDevices()
        AudioDeviceManager.observeDeviceChanges { [weak self] in
            self?.devicesChanged()
        }

        if Self.canUseNotifications {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    var selectedDeviceName: String {
        if let device = devices.first(where: { $0.uid == selectedDeviceUID }) {
            return device.name
        }
        if let id = AudioDeviceManager.defaultInputDeviceID(),
           let device = devices.first(where: { $0.id == id }) {
            return "系統預設（\(device.name)）"
        }
        return "系統預設"
    }

    var menuBarTitle: String {
        guard isRunning else { return "🎙 --" }
        return (isNoisy ? "🔴 " : "🎙 ") + String(format: "%.0f dB", currentDB)
    }

    // MARK: - 控制

    func toggle() {
        isRunning || wantsRunning ? stop() : start()
    }

    func start() {
        wantsRunning = true
        errorMessage = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.wantsRunning else { return }
                    if granted {
                        self.startEngine()
                    } else {
                        self.permissionDenied()
                    }
                }
            }
        default:
            permissionDenied()
        }
    }

    func stop() {
        wantsRunning = false
        stopEngine()
    }

    func clearEvents() {
        events.removeAll { !$0.isOngoing }
    }

    func resetStatistics() {
        sessionMax = 0
        sessionEnergy = 0
        sessionSamples = 0
        sessionOverSamples = 0
        history.removeAll()
        startedAt = isRunning ? Date() : nil
        objectWillChange.send()
    }

    func openLogFolder() {
        NSWorkspace.shared.open(logger.directory)
    }

    func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 音訊引擎

    private func restart() {
        guard wantsRunning else { return }
        stopEngine()
        start()
    }

    private func startEngine() {
        stopEngine()

        var deviceID: AudioDeviceID?
        if !selectedDeviceUID.isEmpty {
            guard let device = devices.first(where: { $0.uid == selectedDeviceUID }) else {
                errorMessage = "找不到選擇的麥克風，請確認外接麥克風已連接（重新插上後會自動恢復監控）。"
                return
            }
            deviceID = device.id
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let deviceID, let unit = input.audioUnit {
            var id = deviceID
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                errorMessage = "無法切換到選擇的麥克風（錯誤碼 \(status)）。"
                return
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            errorMessage = "這個裝置沒有可用的輸入聲道。"
            return
        }

        // 約 0.1 秒一個區塊，接近聲級計的「Fast」時間加權。
        let bufferSize = AVAudioFrameCount(max(1024, format.sampleRate / 10))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let dbfs = AudioMonitor.dbfs(of: buffer) else { return }
            DispatchQueue.main.async {
                self?.process(dbfs: dbfs, at: Date())
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "無法啟動麥克風：\(error.localizedDescription)"
            return
        }

        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // 取樣率或裝置改變時重新建立引擎。
            self?.restart()
        }

        isRunning = true
        if startedAt == nil { startedAt = Date() }
        binStart = Date()
        beginActivity()
    }

    private func stopEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        endActivity()
        if loggingEnabled { logger.flush() }
        finishActiveEvent()
        overStart = nil
        lastAbove = nil
        if isRunning { isRunning = false }
    }

    private func permissionDenied() {
        wantsRunning = false
        errorMessage = "沒有麥克風權限。請到「系統設定 › 隱私權與安全性 › 麥克風」允許 VolumeChecker。"
    }

    private func refreshDevices() {
        devices = AudioDeviceManager.inputDevices()
    }

    private func devicesChanged() {
        refreshDevices()
        let selectedPresent = selectedDeviceUID.isEmpty || devices.contains { $0.uid == selectedDeviceUID }
        if isRunning && !selectedPresent {
            stopEngine()
            errorMessage = "外接麥克風已中斷連線，重新插上後會自動恢復監控。"
        } else if wantsRunning && !isRunning && selectedPresent {
            startEngine()
        }
    }

    /// 防止 App Nap 及（可選）系統閒置睡眠，讓長時間監控不中斷。
    private func beginActivity() {
        endActivity()
        var options: ProcessInfo.ActivityOptions = [.userInitiated]
        if preventSleep { options.insert(.idleSystemSleepDisabled) }
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "正在監控環境音量")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: - 音量計算

    /// 回傳緩衝區所有聲道平均的 RMS 音量（dBFS，0 為數位滿刻度）。
    private static func dbfs(of buffer: AVAudioPCMBuffer) -> Double? {
        guard let data = buffer.floatChannelData else { return nil }
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }

        var total: Float = 0
        for channel in 0..<channels {
            var meanSquare: Float = 0
            vDSP_measqv(data[channel], 1, &meanSquare, frames)
            total += meanSquare
        }
        let meanSquare = Double(total) / Double(channels)
        return 10 * log10(max(meanSquare, 1e-12))
    }

    private func process(dbfs: Double, at now: Date) {
        guard isRunning else { return }
        let db = max(0, dbfs + calibrationOffset)
        let energy = pow(10, db / 10)

        currentDB = db
        sessionMax = max(sessionMax, db)
        sessionEnergy += energy
        sessionSamples += 1
        if db >= threshold { sessionOverSamples += 1 }

        binEnergy += energy
        binSamples += 1
        if now.timeIntervalSince(binStart) >= historyBinSeconds {
            history.append(LevelSample(date: now, db: 10 * log10(binEnergy / Double(binSamples))))
            if history.count > historyLength {
                history.removeFirst(history.count - historyLength)
            }
            binStart = now
            binEnergy = 0
            binSamples = 0
        }

        if loggingEnabled { logger.add(db, at: now) }
        detectEvent(db: db, energy: energy, at: now)
    }

    private func detectEvent(db: Double, energy: Double, at now: Date) {
        if db >= threshold {
            if overStart == nil { overStart = now }
            lastAbove = now
            if !isNoisy, let start = overStart, now.timeIntervalSince(start) >= minDuration {
                let event = NoiseEvent(start: start, end: now, peak: db, energySum: 0, sampleCount: 0)
                events.insert(event, at: 0)
                isNoisy = true
                alert(for: db)
            }
        } else if let last = lastAbove, now.timeIntervalSince(last) >= releaseSeconds {
            finishActiveEvent()
            overStart = nil
            lastAbove = nil
        }

        if isNoisy, !events.isEmpty, events[0].isOngoing {
            events[0].peak = max(events[0].peak, db)
            events[0].energySum += energy
            events[0].sampleCount += 1
            if let lastAbove { events[0].end = lastAbove }
        }
    }

    private func finishActiveEvent() {
        guard isNoisy else { return }
        isNoisy = false
        guard !events.isEmpty, events[0].isOngoing else { return }
        events[0].isOngoing = false
        if loggingEnabled { logger.log(event: events[0]) }
    }

    private func alert(for db: Double) {
        let now = Date()
        if let lastAlert, now.timeIntervalSince(lastAlert) < alertCooldown { return }
        lastAlert = now

        if soundEnabled {
            NSSound(named: NSSound.Name("Funk"))?.play()
        }
        guard notificationsEnabled, Self.canUseNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "環境太吵了"
        content.body = String(
            format: "目前音量 %.0f dB，已超過門檻 %.0f dB 達 %.0f 秒。",
            db, threshold, minDuration
        )
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
