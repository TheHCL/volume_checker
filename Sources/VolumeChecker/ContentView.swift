import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// 圖表與音量條顯示的範圍。
let displayRange: ClosedRange<Double> = 20...110

func levelColor(_ db: Double, threshold: Double) -> Color {
    if db >= threshold { return .red }
    if db >= threshold - 10 { return .orange }
    return .green
}

struct ContentView: View {
    @EnvironmentObject private var monitor: AudioMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let message = monitor.errorMessage {
                errorBanner(message)
            }
            LevelPanel()
            HistoryChart()
                .frame(minHeight: 200)
            HStack(alignment: .top, spacing: 16) {
                EventList()
                    .frame(minWidth: 380)
                SettingsPanel()
                    .frame(width: 380)
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 740)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("麥克風", selection: $monitor.selectedDeviceUID) {
                Text("系統預設輸入").tag("")
                ForEach(monitor.devices) { device in
                    Text(device.name).tag(device.uid)
                }
                if !monitor.selectedDeviceUID.isEmpty,
                   !monitor.devices.contains(where: { $0.uid == monitor.selectedDeviceUID }) {
                    Text("（已中斷連線的裝置）").tag(monitor.selectedDeviceUID)
                }
            }
            .frame(maxWidth: 420)

            Spacer()

            if let startedAt = monitor.startedAt {
                Text("開始於 \(startedAt.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }

            Button {
                monitor.toggle()
            } label: {
                Label(
                    monitor.wantsRunning ? "停止監控" : "開始監控",
                    systemImage: monitor.wantsRunning ? "stop.fill" : "mic.fill"
                )
                .frame(minWidth: 100)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(monitor.wantsRunning ? .red : .accentColor)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
            Spacer()
            if message.contains("權限") {
                Button("開啟系統設定") { monitor.openMicrophonePrivacySettings() }
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 即時音量

struct LevelPanel: View {
    @EnvironmentObject private var monitor: AudioMonitor

    var body: some View {
        let color = monitor.isRunning ? levelColor(monitor.currentDB, threshold: monitor.threshold) : .secondary

        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.isRunning ? String(format: "%.0f", monitor.currentDB) : "--")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(color)
            }
            .frame(width: 180, alignment: .leading)

            if monitor.classificationEnabled {
                SoundGuessView()
                    .frame(width: 170, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 12) {
                LevelBar(value: monitor.isRunning ? monitor.currentDB : displayRange.lowerBound,
                         threshold: monitor.threshold)
                HStack(spacing: 0) {
                    StatView(title: "平均 Leq", value: monitor.sessionLeq)
                    StatView(title: "最大", value: monitor.sessionMax)
                    StatView(title: "超過門檻時間", text: String(format: "%.1f%%", monitor.percentOverThreshold))
                    StatView(title: "吵雜事件", text: "\(monitor.events.count) 次")
                }
                if !monitor.topSounds.isEmpty {
                    Text("本次主要聲音：" + monitor.topSounds
                        .map { String(format: "%@ %.0f%%", $0.name, $0.percent) }
                        .joined(separator: "、"))
                        .font(.callout)
                        .lineLimit(1)
                }
                if monitor.isRunning {
                    Text(String(
                        format: "原始訊號 %.1f dBFS・已收到 %d 個音訊區塊・%@",
                        monitor.rawDBFS, monitor.buffersReceived, monitor.selectedDeviceName
                    ))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusText: String {
        guard monitor.isRunning else { return monitor.wantsRunning ? "等待麥克風…" : "未監控" }
        if monitor.isNoisy { return "dB・吵雜！" }
        if monitor.currentDB >= monitor.threshold { return "dB・偏吵" }
        if monitor.currentDB >= monitor.threshold - 10 { return "dB・稍有聲響" }
        return "dB・安靜"
    }
}

/// 顯示目前最可能的聲音類型與信心度。
struct SoundGuessView: View {
    @EnvironmentObject private var monitor: AudioMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("可能是").font(.caption).foregroundStyle(.secondary)
            if let top = monitor.soundGuesses.first {
                Text(top.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                ForEach(monitor.soundGuesses.dropFirst(), id: \.identifier) { guess in
                    Text(String(format: "%@ %.0f%%", guess.name, guess.confidence * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ProgressView(value: top.confidence)
                    .tint(.blue)
                Text(String(format: "信心度 %.0f%%", top.confidence * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(monitor.isRunning ? "辨識中…" : "--")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatView: View {
    let title: String
    let text: String

    init(title: String, value: Double) {
        self.title = title
        self.text = value > 0 ? String(format: "%.1f dB", value) : "--"
    }

    init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LevelBar: View {
    let value: Double
    let threshold: Double

    private func fraction(_ v: Double) -> CGFloat {
        let clamped = min(max(v, displayRange.lowerBound), displayRange.upperBound)
        return CGFloat((clamped - displayRange.lowerBound) / (displayRange.upperBound - displayRange.lowerBound))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                    LinearGradient(colors: [.green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * fraction(value))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2)
                        .offset(x: geo.size.width * fraction(threshold) - 1)
                }
                .animation(.linear(duration: 0.1), value: value)
            }
            .frame(height: 22)

            HStack {
                Text("\(Int(displayRange.lowerBound)) dB")
                Spacer()
                Text("門檻 \(Int(threshold)) dB")
                Spacer()
                Text("\(Int(displayRange.upperBound)) dB")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 歷史圖表

struct HistoryChart: View {
    @EnvironmentObject private var monitor: AudioMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近 5 分鐘").font(.headline)
            Chart {
                ForEach(monitor.history) { sample in
                    AreaMark(
                        x: .value("時間", sample.date),
                        yStart: .value("下限", displayRange.lowerBound),
                        yEnd: .value("音量", min(max(sample.db, displayRange.lowerBound), displayRange.upperBound))
                    )
                    .foregroundStyle(.blue.opacity(0.15))
                    LineMark(
                        x: .value("時間", sample.date),
                        y: .value("音量", min(max(sample.db, displayRange.lowerBound), displayRange.upperBound))
                    )
                    .foregroundStyle(.blue)
                }
                RuleMark(y: .value("門檻", monitor.threshold))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("門檻 \(Int(monitor.threshold)) dB")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
            }
            .chartYScale(domain: displayRange)
            .chartYAxisLabel("dB")
            .overlay {
                if monitor.history.isEmpty {
                    Text("按「開始監控」後會在這裡顯示音量變化")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 吵雜事件

struct EventList: View {
    @EnvironmentObject private var monitor: AudioMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("吵雜事件").font(.headline)
                Spacer()
                Button("匯出 CSV…", action: exportCSV)
                    .disabled(monitor.events.isEmpty)
                Button("清除", action: monitor.clearEvents)
                    .disabled(monitor.events.isEmpty)
            }
            List(monitor.events) { event in
                HStack {
                    Circle()
                        .fill(event.isOngoing ? Color.red : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(event.start.formatted(date: .abbreviated, time: .standard))
                        .monospacedDigit()
                    Spacer()
                    if let sound = event.dominantSound {
                        Text(sound)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Text(event.isOngoing ? "進行中" : formatDuration(event.duration))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    Text(String(format: "最大 %.0f dB", event.peak))
                        .monospacedDigit()
                        .frame(width: 90, alignment: .trailing)
                }
            }
            .overlay {
                if monitor.events.isEmpty {
                    Text("目前沒有超過門檻的事件")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60) 分 \(s % 60) 秒" : "\(s) 秒"
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "noise-events-\(day).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try monitor.logger.exportEvents(monitor.events, to: url)
        } catch {
            monitor.errorMessage = "匯出失敗：\(error.localizedDescription)"
        }
    }
}

// MARK: - 設定

struct SettingsPanel: View {
    @EnvironmentObject private var monitor: AudioMonitor

    var body: some View {
        Form {
            Section("提醒條件") {
                LabeledSlider(
                    title: "音量門檻",
                    value: $monitor.threshold,
                    range: 30...100,
                    step: 1,
                    format: "%.0f dB"
                )
                LabeledSlider(
                    title: "持續超過",
                    value: $monitor.minDuration,
                    range: 0...60,
                    step: 1,
                    format: "%.0f 秒"
                )
                Toggle("系統通知", isOn: $monitor.notificationsEnabled)
                    .disabled(!AudioMonitor.canUseNotifications)
                    .help(AudioMonitor.canUseNotifications ? "" : "需要以 .app 方式執行才能發送通知（請使用 scripts/build_app.sh）")
                Toggle("播放提示音", isOn: $monitor.soundEnabled)
            }

            Section {
                Toggle("辨識聲音類型", isOn: $monitor.classificationEnabled)
            } header: {
                Text("聲音辨識")
            } footer: {
                Text("使用 macOS 內建的聲音分類模型，在本機辨識約 300 種聲音（車輛、喇叭、警笛、說話、狗叫…），不需網路。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledSlider(
                    title: "校正值",
                    value: $monitor.calibrationOffset,
                    range: 60...140,
                    step: 0.5,
                    format: "+%.1f"
                )
            } header: {
                Text("校正")
            } footer: {
                Text("麥克風只能量到相對音量 (dBFS)。拿手機分貝計 App 放在麥克風旁，調整校正值讓兩邊數字接近即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("紀錄") {
                Toggle("每分鐘記錄音量到 CSV", isOn: $monitor.loggingEnabled)
                Toggle("監控時防止電腦睡眠", isOn: $monitor.preventSleep)
                HStack {
                    Button("開啟紀錄資料夾", action: monitor.openLogFolder)
                    Button("重設統計", action: monitor.resetStatistics)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
