import SwiftUI
import AppKit

struct InstanceDetail: View {
    @ObservedObject var model: AppModel
    let instance: ScriptInstance
    @State private var confirmDelete = false
    @State private var pendingSlot: (deviceID: String, key: String, ownerID: UUID, ownerName: String)?
    private var script: InstalledScript? { model.data.installedScripts.first { $0.id == instance.scriptID } }
    private var slots: [DotSlot] {
        guard let script else { return [] }
        return (model.data.slots[instance.deviceID] ?? []).filter { $0.type == script.manifest.outputType.slotType && $0.key != nil }
    }
    private func binding<T>(_ keyPath: WritableKeyPath<ScriptInstance, T>) -> Binding<T> {
        Binding(get: { model.data.instances.first(where: { $0.id == instance.id })?[keyPath: keyPath] ?? instance[keyPath: keyPath] },
                set: { value in model.updateInstance(instance.id) { $0[keyPath: keyPath] = value } })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(script?.manifest.name ?? instance.scriptID).font(.title3.weight(.semibold))
                        Text(script?.manifest.description ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("启用", isOn: binding(\.enabled)).toggleStyle(.switch)
                        .disabled(instance.taskKey.isEmpty)
                    Button("删除内容", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .confirmationDialog("删除“\(script?.manifest.name ?? instance.scriptID)”的这个内容任务？", isPresented: $confirmDelete) {
                            Button("删除内容", role: .destructive) { model.deleteInstance(instance.id) }
                        } message: {
                            Text("脚本仍会保留在已安装列表；设备内容槽不会被删除，可绑定其他任务。")
                        }
                }
                if let script {
                    LabeledContent("类型", value: script.manifest.outputType.title)
                    Picker("设备", selection: binding(\.deviceID)) {
                        Text("请选择设备").tag("")
                        ForEach(model.data.devices) { device in Text(device.name).tag(device.id) }
                    }
                    Picker("内容槽", selection: Binding(get: {
                        model.data.instances.first(where: { $0.id == instance.id })?.taskKey ?? instance.taskKey
                    }, set: { key in
                        if let owner = model.data.slotOwner(deviceID: instance.deviceID, taskKey: key, excluding: instance.id) {
                            let name = model.data.installedScripts.first(where: { $0.id == owner.scriptID })?.manifest.name ?? owner.scriptID
                            pendingSlot = (instance.deviceID, key, owner.id, name)
                        } else {
                            model.assignSlot(key, to: instance.id)
                        }
                    })) {
                        Text("请选择内容槽").tag("")
                        ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                            let owner = model.data.slotOwner(deviceID: instance.deviceID, taskKey: slot.key ?? "", excluding: instance.id)
                            let ownerName = owner.flatMap { owner in model.data.installedScripts.first(where: { $0.id == owner.scriptID })?.manifest.name }
                            Text("\(script.manifest.outputType.title)槽 \(index + 1) · \(String((slot.key ?? "").suffix(6)))\(ownerName.map { " · \($0)" } ?? "")").tag(slot.key ?? "")
                        }
                    }
                    if slots.isEmpty { Text("请先在 Dot. App 添加对应 API 循环内容槽，再同步槽位。").font(.caption).foregroundStyle(.orange) }
                    else if instance.taskKey.isEmpty { Text("请选择一个\(script.manifest.outputType.title)内容槽，随后即可启用定时更新。").font(.caption).foregroundStyle(.orange) }
                    Divider()
                    ScheduleEditor(model: model, instance: instance).id(instance.id)
                    Divider()
                    Text("脚本参数").font(.headline)
                    Text("以下字段由脚本的 script.json 声明；填写的值会作为参数传给脚本。修改后自动保存。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(script.manifest.parameters) { parameter in
                        ParameterEditor(model: model, instance: instance, parameter: parameter)
                    }
                    if !script.manifest.requirements.isEmpty {
                        Text("运行环境：\(script.manifest.requirements.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("测试脚本") { Task { await model.run(instance.id, push: false) } }
                        Button("更新内容") { Task { await model.run(instance.id, push: true) } }.disabled(instance.taskKey.isEmpty)
                        Button("立即显示") { Task { await model.run(instance.id, push: true, immediate: true) } }.disabled(instance.taskKey.isEmpty)
                        Spacer()
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Button("测试脚本") { Task { await model.run(instance.id, push: false) } }
                            Button("更新内容") { Task { await model.run(instance.id, push: true) } }.disabled(instance.taskKey.isEmpty)
                            Button("立即显示") { Task { await model.run(instance.id, push: true, immediate: true) } }.disabled(instance.taskKey.isEmpty)
                        }
                    }
                    }.buttonStyle(.bordered)
                    if let preview = model.previews[instance.id] {
                        Divider()
                        Text("最近测试结果").font(.headline)
                        ResultPreview(result: preview, directory: URL(fileURLWithPath: script.directory))
                    }
                }
            }.padding(22).frame(maxWidth: 680, alignment: .leading)
        }
        .confirmationDialog("“\(pendingSlot?.ownerName ?? "")”正在使用此内容槽", isPresented: Binding(get: { pendingSlot != nil }, set: { if !$0 { pendingSlot = nil } })) {
            Button("替换并更新新内容") {
                if let pendingSlot {
                    Task { await model.replaceSlot(pendingSlot.key, deviceID: pendingSlot.deviceID,
                                                   ownerID: pendingSlot.ownerID, with: instance.id) }
                }
                pendingSlot = nil
            }
            Button("取消", role: .cancel) { pendingSlot = nil }
        } message: {
            Text("将由“\(script?.manifest.name ?? instance.scriptID)”接管此槽位。请先填写新任务的必填参数；写入成功后旧任务停止定时更新，失败则保留原绑定。详情可在运行记录查看。")
        }
    }
}

private struct ScheduleEditor: View {
    @ObservedObject var model: AppModel
    let instance: ScriptInstance
    @State private var customMinutes = ""
    @State private var showingCustomInterval = false
    private let presets = [5, 10, 15, 30, 60, 120, 360, 720]
    private var mode: String { if case .daily = instance.schedule { "daily" } else { "interval" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("脚本执行计划").font(.headline)
            Text("客户端按此计划运行脚本，并将结果更新到绑定的内容槽；这不是脚本参数。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("方式", selection: Binding(get: { mode }, set: { value in model.updateInstance(instance.id) { $0.schedule = value == "daily" ? .daily(hour: 9, minute: 0) : .interval(30); $0.nextRun = $0.schedule.next(after: Date()) } })) {
                Text("每隔 N 分钟").tag("interval")
                Text("每天指定时间").tag("daily")
            }.pickerStyle(.segmented)
            switch instance.schedule {
            case .interval(let minutes):
                HStack {
                    Text("执行间隔").frame(width: 86, alignment: .leading)
                    Menu {
                        ForEach(presets, id: \.self) { value in
                            Button {
                                model.updateInstance(instance.id) { $0.schedule = .interval(value) }
                            } label: {
                                if minutes == value { Label("\(value) 分钟", systemImage: "checkmark") }
                                else { Text("\(value) 分钟") }
                            }
                        }
                        Divider()
                        Button("自定义…") {
                            customMinutes = String(minutes)
                            showingCustomInterval = true
                        }
                    } label: {
                        Text(presets.contains(minutes) ? "\(minutes) 分钟" : "自定义 · \(minutes) 分钟")
                            .frame(width: 150, alignment: .leading)
                    }
                    .popover(isPresented: $showingCustomInterval) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("自定义执行间隔").font(.headline)
                            HStack {
                                TextField("分钟", text: $customMinutes)
                                    .frame(width: 80)
                                    .onSubmit { applyCustomInterval() }
                                Text("分钟").foregroundStyle(.secondary)
                            }
                            Text("可设置 1–720 分钟").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Spacer()
                                Button("取消") { showingCustomInterval = false }
                                Button("保存") { applyCustomInterval() }
                                    .disabled(Int(customMinutes).map { !(1...720).contains($0) } ?? true)
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(16)
                        .frame(width: 250)
                    }
                }
            case .daily(let hour, let minute):
                HStack {
                    Text("每天")
                    Picker("小时", selection: Binding(get: { hour }, set: { value in model.updateInstance(instance.id) { $0.schedule = .daily(hour: value, minute: minute); $0.nextRun = $0.schedule.next(after: Date()) } })) {
                        ForEach(0..<24) { Text(String(format: "%02d", $0)).tag($0) }
                    }.frame(width: 100)
                    Picker("分钟", selection: Binding(get: { minute }, set: { value in model.updateInstance(instance.id) { $0.schedule = .daily(hour: hour, minute: value); $0.nextRun = $0.schedule.next(after: Date()) } })) {
                        ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) }
                    }.frame(width: 100)
                }
            }
            if let next = instance.nextRun { Text("下次运行：\(AppDateFormat.short(next))").font(.caption).foregroundStyle(.secondary) }
            Text("执行计划修改后自动保存并生效；无需关闭或重新启用任务。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func applyCustomInterval() {
        guard let value = Int(customMinutes), (1...720).contains(value) else { return }
        model.updateInstance(instance.id) { $0.schedule = .interval(value) }
        showingCustomInterval = false
    }
}

private struct ParameterEditor: View {
    @ObservedObject var model: AppModel
    let instance: ScriptInstance
    let parameter: ScriptParameter
    private func set(_ value: JSONValue) { model.updateInstance(instance.id) { $0.parameters[parameter.key] = value } }
    private var current: JSONValue { model.data.instances.first(where: { $0.id == instance.id })?.parameters[parameter.key] ?? parameter.defaultValue ?? .null }
    var body: some View {
        if parameter.type == "image" {
            ImageParameterEditor(model: model, instance: instance, parameter: parameter)
        } else {
            HStack(alignment: parameter.type == "multiline" ? .top : .center, spacing: 14) {
                Text(parameter.label)
                    .frame(width: 110, alignment: .leading)
                control.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    @ViewBuilder private var control: some View {
        switch parameter.type {
        case "boolean":
            Toggle(parameter.label, isOn: Binding(get: { if case .bool(let value) = current { value } else { false } }, set: { set(.bool($0)) }))
                .labelsHidden().toggleStyle(.switch).accessibilityLabel(parameter.label)
        case "enum":
            Picker(parameter.label, selection: Binding(get: { current.string ?? "" }, set: { set(.string($0)) })) {
                ForEach(parameter.options ?? [], id: \.self) { Text($0).tag($0) }
            }.labelsHidden().accessibilityLabel(parameter.label)
        case "secret":
            SecureField("", text: Binding(get: { current.string ?? "" }, set: { set(.string($0)) }))
                .accessibilityLabel(parameter.label)
        case "number":
            TextField("", text: Binding(get: { if case .number(let value) = current { String(value) } else { "" } }, set: { set(.number(Double($0) ?? 0)) }))
                .accessibilityLabel(parameter.label)
        case "multiline":
            TextEditor(text: Binding(get: { current.string ?? "" }, set: { set(.string($0)) }))
                .font(.body).frame(minHeight: 88)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.12)))
                .accessibilityLabel(parameter.label)
        default:
            TextField("", text: Binding(get: { current.string ?? "" }, set: { set(.string($0)) }))
                .accessibilityLabel(parameter.label)
        }
    }
}

struct ResultPreview: View {
    let result: ScriptResult
    let directory: URL
    var body: some View {
        switch result.type {
        case .text:
            VStack(alignment: .leading, spacing: 8) {
                Text(result.content["title"]?.string ?? "").font(.headline)
                Text(result.content["message"]?.string ?? "").font(.body)
                Spacer(minLength: 0)
                Text(result.content["signature"]?.string ?? "").font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).frame(width: 296, height: 152, alignment: .topLeading)
            .background(.white).border(.black.opacity(0.2))
        case .image:
            if let nsImage = previewImage {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit).frame(width: 296, height: 152).border(.black.opacity(0.2))
            } else { Text("图像结果已生成；远程图片由设备端渲染").foregroundStyle(.secondary) }
        case .canvas:
            let values = result.content["data"]?.object ?? [:]
            if let title = values["title"]?.string {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(values["badge"]?.string ?? "CANVAS").font(.system(size: 10, weight: .bold))
                        Spacer()
                        Text(values["status"]?.string ?? "").font(.system(size: 10))
                    }
                    Spacer(minLength: 0)
                    Text(title).font(.system(size: 27, weight: .bold)).lineLimit(2)
                    Text(values["message"]?.string ?? "").font(.system(size: 14)).lineLimit(3)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Circle().frame(width: 6, height: 6)
                        Text(values["footer"]?.string ?? "").font(.system(size: 10)).lineLimit(1)
                    }
                    Text("画板由 Dot. 服务端最终渲染").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.black)
                .padding(12)
                .frame(width: 296, height: 152, alignment: .topLeading)
                .background(.white)
                .border(.black.opacity(0.2))
            } else {
                VStack(alignment: .leading) {
                    Text("画板数据").font(.caption.weight(.semibold))
                    ForEach(values.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(values[key]?.string ?? "…")").font(.caption)
                    }
                    Text("实际画面由 Dot. 服务端渲染").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var previewImage: NSImage? {
        if let file = result.content["imageFile"]?.string {
            return NSImage(contentsOf: URL(fileURLWithPath: file, relativeTo: directory))
        }
        if let raw = result.content["image"]?.string, raw.hasPrefix("data:image/png;base64,"),
           let data = Data(base64Encoded: String(raw.dropFirst("data:image/png;base64,".count))) {
            return NSImage(data: data)
        }
        return nil
    }
}
