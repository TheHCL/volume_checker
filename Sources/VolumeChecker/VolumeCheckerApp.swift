import AppKit
import SwiftUI
import UserNotifications

@main
struct VolumeCheckerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = AudioMonitor()

    var body: some Scene {
        Window("Volume Checker 音量監控", id: "main") {
            ContentView()
                .environmentObject(monitor)
        }
        .defaultSize(width: 960, height: 760)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(monitor)
        } label: {
            Text(monitor.menuBarTitle)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 用 `swift run` 直接執行時也要出現在 Dock 並取得焦點。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if AudioMonitor.canUseNotifications {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// 關閉主視窗後仍在選單列繼續監控。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// App 在前景時也顯示通知橫幅。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var monitor: AudioMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if monitor.isRunning {
            Text(String(format: "目前音量：%.0f dB（門檻 %.0f dB）", monitor.currentDB, monitor.threshold))
            Text(String(format: "平均 Leq：%.0f dB　最大：%.0f dB", monitor.sessionLeq, monitor.sessionMax))
            if let sound = monitor.soundGuesses.first {
                Text(String(format: "可能是：%@（%.0f%%）", sound.name, sound.confidence * 100))
            }
        } else {
            Text("尚未開始監控")
        }
        Text("麥克風：\(monitor.selectedDeviceName)")
        Divider()
        Button(monitor.wantsRunning ? "停止監控" : "開始監控") {
            monitor.toggle()
        }
        Button("開啟主視窗") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("開啟紀錄資料夾") {
            monitor.openLogFolder()
        }
        Divider()
        Button("結束 Volume Checker") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
