import SwiftUI
import AppKit

@main
struct Quote0UIApp: App {
    @NSApplicationDelegateAdaptor(QuoteAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("quote0UI", id: "main") {
            MainView(model: model)
                .frame(minWidth: 700, minHeight: 500)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("内容") {
                Button("同步设备内容槽") { Task { await model.syncDevice() } }
                    .keyboardShortcut("r", modifiers: [.command])
                Button(model.data.paused ? "恢复定时任务" : "暂停定时任务") {
                    model.data.paused.toggle(); model.persist()
                }
            }
        }
        MenuBarExtra("quote0UI", systemImage: "rectangle.on.rectangle") {
            QuoteMenu(model: model).preferredColorScheme(.light)
        }
        .menuBarExtraStyle(.window)
    }
}

private final class QuoteAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        guard let window = sender.windows.first(where: { $0.title == "quote0UI" && $0.styleMask.contains(.titled) }) else {
            return true
        }
        window.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return false
    }
}

private struct QuoteMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.tint)
                Text("quote0UI").font(.headline)
                Spacer()
                Text(model.data.paused ? "已暂停" : "运行中").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let active = model.data.instances.filter(\.enabled)
                let next = active.compactMap(\.nextRun).min()
                let relative = next.map { relativeTime(until: $0, from: context.date) } ?? "暂无计划"
                Text("已启用 \(active.count) 个脚本 · 下次运行 \(model.data.paused ? "已暂停" : relative)")
                    .font(.subheadline).lineLimit(1)
            }
            if let last = model.data.records.first, last.status == "失败" {
                Label(last.detail, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            Divider()
            Button("打开主窗口") {
                if let window = NSApp.windows.first(where: { $0.title == "quote0UI" && $0.styleMask.contains(.titled) }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: "main")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(model.data.paused ? "恢复全部" : "暂停全部") { model.data.paused.toggle(); model.persist() }
            Button("退出 quote0UI") { NSApp.terminate(nil) }
        }
        .padding(16)
        .frame(width: 280)
    }
    private func relativeTime(until date: Date, from now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 60 { return "即将运行" }
        if seconds < 3_600 { return "\(Int(ceil(seconds / 60))) 分钟后" }
        if seconds < 86_400 { return "\(Int(ceil(seconds / 3_600))) 小时后" }
        return "\(Int(ceil(seconds / 86_400))) 天后"
    }
}
