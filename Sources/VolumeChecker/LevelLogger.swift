import Foundation

/// 將每分鐘的音量統計與吵雜事件寫成 CSV，方便之後用 Excel / Numbers 分析。
///
/// 檔案位置：~/Library/Application Support/VolumeChecker/
/// - levels-YYYY-MM-DD.csv：每分鐘一列（Leq / 最小 / 最大）
/// - events.csv：每個吵雜事件一列
final class LevelLogger {
    let directory: URL

    private var minuteStart: Date?
    private var energySum = 0.0
    private var sampleCount = 0
    private var minDB = Double.infinity
    private var maxDB = -Double.infinity

    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        directory = base.appendingPathComponent("VolumeChecker", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func add(_ db: Double, at date: Date) {
        let minute = Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
        if let current = minuteStart, current != minute {
            flush()
        }
        if minuteStart == nil {
            minuteStart = minute
        }
        energySum += pow(10, db / 10)
        sampleCount += 1
        minDB = min(minDB, db)
        maxDB = max(maxDB, db)
    }

    /// 把目前累積的這一分鐘寫入檔案（停止監控時也會呼叫）。
    func flush() {
        defer { resetMinute() }
        guard let start = minuteStart, sampleCount > 0 else { return }
        let leq = 10 * log10(energySum / Double(sampleCount))
        let line = String(
            format: "%@,%.1f,%.1f,%.1f\n",
            timestampFormatter.string(from: start), leq, minDB, maxDB
        )
        let file = directory.appendingPathComponent("levels-\(dayFormatter.string(from: start)).csv")
        append(line, to: file, header: "時間,平均音量Leq(dB),最小(dB),最大(dB)\n")
    }

    func log(event: NoiseEvent) {
        let file = directory.appendingPathComponent("events.csv")
        append(Self.csvRow(for: event, formatter: timestampFormatter), to: file, header: Self.eventsHeader)
    }

    /// 匯出全部事件（含 BOM，Excel 開啟中文不會亂碼）。
    func exportEvents(_ events: [NoiseEvent], to url: URL) throws {
        var text = "\u{FEFF}" + Self.eventsHeader
        for event in events.sorted(by: { $0.start < $1.start }) {
            text += Self.csvRow(for: event, formatter: timestampFormatter)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static let eventsHeader = "開始時間,結束時間,持續秒數,最大音量(dB),平均音量Leq(dB)\n"

    private static func csvRow(for event: NoiseEvent, formatter: DateFormatter) -> String {
        String(
            format: "%@,%@,%.0f,%.1f,%.1f\n",
            formatter.string(from: event.start),
            formatter.string(from: event.end),
            event.duration,
            event.peak,
            event.leq
        )
    }

    private func resetMinute() {
        minuteStart = nil
        energySum = 0
        sampleCount = 0
        minDB = .infinity
        maxDB = -.infinity
    }

    private func append(_ line: String, to file: URL, header: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: Data(("\u{FEFF}" + header).utf8))
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
