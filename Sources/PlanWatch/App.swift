import AppKit
import SwiftUI
import UserNotifications
import PlanWatchCore

final class ApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
@MainActor
struct PlanWatchApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var store = Store()
    var body: some Scene {
        MenuBarExtra {
            Dashboard(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.menuSymbol)
                if store.configuration.showMenuPercent {
                    if let used = store.menuUsage { Text("\(Int(max(0, 100 - used)))%") }
                    else { Text("—") }
                }
            }
            .help("PlanWatch · 点击查看额度；百分比为所选订阅的最少剩余量")
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(store: store)
        }
    }
}
