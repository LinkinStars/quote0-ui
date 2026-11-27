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

@MainActor private final class QuoteAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.title == "quote0UI", window.styleMask.contains(.titled) else { return }
        DispatchQueue.main.async {
            let mainWindowVisible = NSApp.windows.contains {
                $0.title == "quote0UI" && $0.styleMask.contains(.titled) && $0.isVisible
            }
            if !mainWindowVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        sender.setActivationPolicy(.regular)
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
    private let background = Color(red: 0.975, green: 0.975, blue: 0.972)
    private let blue = Color(red: 0.17, green: 0.39, blue: 0.78)
    private var recentFailure: Bool { model.data.records.first?.status == "失败" }
    private var statusColor: Color { model.data.paused || recentFailure ? .orange : .green }
    private var statusTitle: String {
        if model.data.paused { return "已暂停" }
        return recentFailure ? "更新失败" : "运行中"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("quote0UI").font(.system(size: 15, weight: .semibold))
                    Text("Quote/0 内容管理").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusTitle)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(statusColor.opacity(0.10), in: Capsule())
            }
            .padding(.bottom, 14)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                let active = model.data.instances.filter(\.enabled)
                let next = active.compactMap(\.nextRun).min()
                let relative = next.map { relativeTime(until: $0, from: context.date) } ?? "暂无计划"
                HStack(spacing: 0) {
                    metric(title: "已启用任务", value: "\(active.count) 个")
                    Rectangle().fill(.black.opacity(0.08)).frame(width: 1, height: 32)
                    metric(title: "下次运行", value: model.data.paused ? "已暂停" : relative)
                }
                .padding(.vertical, 11)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.06)))
            }

            MenuActionRow(title: "打开主窗口", symbol: "rectangle.on.rectangle", prominent: true) {
                NSApp.setActivationPolicy(.regular)
                if let window = NSApp.windows.first(where: { $0.title == "quote0UI" && $0.styleMask.contains(.titled) }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: "main")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            .padding(.top, 12)

            MenuActionRow(title: model.data.paused ? "恢复定时任务" : "暂停定时任务",
                          symbol: model.data.paused ? "play.fill" : "pause.fill") {
                model.data.paused.toggle()
                model.persist()
            }
            .padding(.top, 6)

            HStack {
                Text(recentFailure ? "上次更新失败，请在运行记录中查看" : "关闭窗口后仍在后台运行")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(recentFailure ? (model.data.records.first?.detail ?? "") : "")
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .modifier(QuietMenuFocus())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 14)
        }
        .padding(16)
        .frame(width: 312, height: 260)
        .background(background)
        .tint(blue)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
    }

    private func relativeTime(until date: Date, from now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 60 { return "即将运行" }
        if seconds < 3_600 { return "\(Int(ceil(seconds / 60))) 分钟后" }
        if seconds < 86_400 { return "\(Int(ceil(seconds / 3_600))) 小时后" }
        return "\(Int(ceil(seconds / 86_400))) 天后"
    }
}

private struct MenuActionRow: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).fontWeight(prominent ? .semibold : .medium)
                Spacer()
                if prominent { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)) }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(prominent ? Color.accentColor.opacity(0.11) : .white,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(prominent ? 0 : 0.06)))
        }
        .buttonStyle(.plain)
        .modifier(QuietMenuFocus())
        .foregroundStyle(prominent ? Color.accentColor : .primary)
    }
}

private struct QuietMenuFocus: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.focusEffectDisabled() }
        else { content }
    }
}
