import SwiftUI

struct OverviewPage: View {
    @ObservedObject var model: AppModel

    private var deviceID: String { model.data.selectedDeviceID }
    private var deviceName: String {
        model.data.devices.first { $0.id == deviceID }?.name ?? "Quote/0"
    }
    private var slots: [DotSlot] { model.data.slots[deviceID] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    PageTitle(title: "设备概览", subtitle: "\(deviceName) · 已同步 \(slots.count) 个循环内容槽")
                    Button { Task { await model.syncDevice() } } label: {
                        Label("同步槽位", systemImage: "arrow.clockwise")
                    }
                    .disabled(deviceID.isEmpty)
                }
                if deviceID.isEmpty {
                    emptyState("尚未连接设备", detail: "前往设置连接 Quote/0，再同步循环内容槽。")
                    Button("打开设置") { model.selectedPage = .settings }
                } else if slots.isEmpty {
                    emptyState("还没有同步内容槽", detail: "先在 Dot. App 添加 API 内容槽，然后点击同步槽位。")
                } else {
                    ViewThatFits(in: .horizontal) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in slotCard(slot, index: index) }
                        }
                        .frame(minWidth: 704)
                        LazyVGrid(columns: [GridItem(.flexible())], spacing: 16) {
                            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in slotCard(slot, index: index) }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func slotCard(_ slot: DotSlot, index: Int) -> some View {
        let type = OutputType.allCases.first { $0.slotType == slot.type }
        let owner = model.data.instances.first { $0.deviceID == deviceID && $0.taskKey == slot.key && slot.key != nil }
        let script = owner.flatMap { current in model.data.installedScripts.first { $0.id == current.scriptID } }
        let updating = owner?.enabled == true && !model.data.paused
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(type?.title ?? "内容")槽 \(index + 1)", systemImage: type?.symbol ?? "square")
                    .font(.headline)
                Spacer()
                Text(String((slot.key ?? "").suffix(6))).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Divider()
            if let owner, let script {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(script.manifest.name).fontWeight(.medium).lineLimit(1)
                        Text(scheduleText(owner.schedule)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(updating ? "定时更新中" : "已暂停", systemImage: updating ? "checkmark.circle" : "pause.circle")
                        .font(.caption).foregroundStyle(updating ? .green : .secondary)
                }
                .frame(height: 44)
                Text("最近预览 · 设备画面以实际同步结果为准")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(height: 18, alignment: .leading)
                if let preview = model.previews[owner.id] {
                    ResultPreview(result: preview, directory: URL(fileURLWithPath: script.directory))
                        .frame(width: 296, height: 152, alignment: .topLeading)
                } else {
                    previewPlaceholder("尚无预览 · 测试脚本后显示预期画面")
                }
                Text(owner.lastRun.map { "最近运行：\(AppDateFormat.short($0)) · \(owner.lastStatus ?? "")" } ?? "尚未运行")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(height: 18, alignment: .leading)
                Spacer(minLength: 0)
                HStack {
                    Button("打开任务") {
                        model.selectedInstanceID = owner.id
                        model.selectedPage = .content
                    }
                    Button("生成预览") { Task { await model.run(owner.id, push: false) } }
                }
            } else {
                Text("未绑定脚本").fontWeight(.medium).frame(height: 44, alignment: .leading)
                Text("预览").font(.caption).foregroundStyle(.secondary).frame(height: 18, alignment: .leading)
                previewPlaceholder("未绑定脚本 · 设备可能已有其他内容")
                Text("尚未运行").font(.caption).foregroundStyle(.secondary).frame(height: 18, alignment: .leading)
                Spacer(minLength: 0)
                Button("前往内容") { model.selectedPage = .content }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 400, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.08)))
    }

    private func previewPlaceholder(_ message: String) -> some View {
        Text(message)
            .font(.caption).foregroundStyle(.secondary)
            .frame(width: 296, height: 152)
            .background(Color.black.opacity(0.025))
            .overlay(Rectangle().strokeBorder(.black.opacity(0.12)))
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "rectangle.3.group").font(.title).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
    }

    private func scheduleText(_ schedule: RunSchedule) -> String {
        switch schedule {
        case .interval(let minutes): "每隔 \(minutes) 分钟执行"
        case .daily(let hour, let minute): String(format: "每天 %02d:%02d 执行", hour, minute)
        }
    }
}
