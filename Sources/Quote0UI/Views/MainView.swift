import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct QuietNavigationFocus: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.focusEffectDisabled() }
        else { content }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    private let background = Color(red: 250/255, green: 250/255, blue: 249/255)
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(AppPage.allCases) { page in
                    Button { model.selectedPage = page } label: {
                        Label(page.rawValue, systemImage: page.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(QuietNavigationFocus())
                    .frame(maxWidth: .infinity)
                    .background(model.selectedPage == page ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityAddTraits(model.selectedPage == page ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 24)
            .frame(width: 184)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(red: 246/255, green: 246/255, blue: 245/255))
            Rectangle().fill(.black.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                Group {
                    switch model.selectedPage {
                    case .overview: OverviewPage(model: model)
                    case .content: ContentPage(model: model)
                    case .market: MarketPage(model: model)
                    case .history: HistoryPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                if !model.statusMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(model.statusMessage).lineLimit(2)
                        Spacer()
                        Button { model.statusMessage = "" } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("关闭提示")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.vertical, 8).background(.white)
                }
            }
            .background(background.ignoresSafeArea())
        }
        .tint(.blue)
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 24, weight: .semibold, design: .serif))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ContentPage: View {
    @ObservedObject var model: AppModel
    @FocusState private var focusedInstanceID: UUID?
    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PageTitle(title: "内容", subtitle: "脚本更新内容，Quote/0 按设备间隔轮播")
                Button { Task { await model.syncDevice() } } label: { Label("同步槽位", systemImage: "arrow.clockwise") }
                    .disabled(model.data.selectedDeviceID.isEmpty)
            }
            if geometry.size.width < 760 {
                Picker("脚本任务", selection: $model.selectedInstanceID) {
                    Text("选择任务").tag(nil as UUID?)
                    ForEach(model.data.instances) { instance in
                        Text(model.data.installedScripts.first { $0.id == instance.scriptID }?.manifest.name ?? instance.scriptID)
                            .tag(instance.id as UUID?)
                    }
                }
                if let id = model.selectedInstanceID, let instance = model.data.instances.first(where: { $0.id == id }) {
                    InstanceDetail(model: model, instance: instance)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                } else { emptyContent }
            } else {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                    ForEach(model.data.instances) { instance in
                        let script = model.data.installedScripts.first { $0.id == instance.scriptID }
                        Button {
                            model.selectedInstanceID = instance.id
                            focusedInstanceID = instance.id
                        } label: { VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: script?.manifest.outputType.symbol ?? "questionmark")
                                    .foregroundStyle(.secondary)
                                Text(script?.manifest.name ?? instance.scriptID).fontWeight(.medium).lineLimit(1)
                                Spacer()
                                Circle().fill(instance.enabled ? .green : .gray).frame(width: 6, height: 6)
                            }
                            Text(instance.lastStatus ?? "待配置").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .focused($focusedInstanceID, equals: instance.id)
                        .modifier(QuietNavigationFocus())
                        .background(model.selectedInstanceID == instance.id ? Color.accentColor.opacity(0.10) : .clear)
                        .accessibilityAddTraits(model.selectedInstanceID == instance.id ? .isSelected : [])
                    }
                    }
                }
                .onMoveCommand { direction in
                    guard let current = model.data.instances.firstIndex(where: { $0.id == model.selectedInstanceID }) else { return }
                    let next = direction == .down ? min(current + 1, model.data.instances.count - 1) : max(current - 1, 0)
                    guard model.data.instances.indices.contains(next) else { return }
                    model.selectedInstanceID = model.data.instances[next].id
                    focusedInstanceID = model.selectedInstanceID
                }
                .frame(minWidth: 210, idealWidth: 245, maxWidth: 300)
                .background(Color.black.opacity(0.018))
                Rectangle()
                    .fill(Color.black.opacity(0.10))
                    .frame(width: 1)
                    .accessibilityHidden(true)
                if let id = model.selectedInstanceID, let instance = model.data.instances.first(where: { $0.id == id }) {
                    InstanceDetail(model: model, instance: instance)
                } else {
                    emptyContent
                }
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.07)))
            }
        }
        .padding(24)
        .frame(maxWidth: 1120, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .onAppear { if model.selectedInstanceID == nil { model.selectedInstanceID = model.data.instances.first?.id } }
        }
    }
    private var emptyContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(.secondary)
            Text("尚无内容").font(.headline)
            Text("从脚本市场添加脚本，或导入本地脚本").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MarketPage: View {
    @ObservedObject var model: AppModel
    @State private var importing = false
    @State private var pendingInstall: MarketScript?
    @State private var pendingLocal: URL?
    @State private var pendingUpdate: MarketScript?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageTitle(title: "脚本市场", subtitle: "安装示例脚本，或添加公开 GitHub 仓库中的脚本目录")
                HStack {
                    TextField("https://github.com/用户/仓库/tree/main/ScriptCatalog", text: $model.repositoryInput)
                    Button("添加仓库") { model.addRepository() }
                    Button { Task { await model.refreshMarket() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("检查脚本更新")
                }
                if !model.data.repositories.isEmpty {
                    ForEach(model.data.repositories, id: \.self) { repo in
                        HStack {
                            Image(systemName: "shippingbox")
                            Text(repo).font(.caption).lineLimit(1)
                            Spacer()
                            Button("移除") { model.removeRepository(repo) }.buttonStyle(.link)
                        }
                    }
                }
                HStack {
                    Text("已安装脚本").font(.headline)
                    Spacer()
                    Button("导入本地脚本…") { importing = true }
                }
                ForEach(model.data.installedScripts) { script in
                    ScriptRow(manifest: script.manifest, detail: script.availableUpdateSHA == nil ? "已安装 · \(script.manifest.version)" : "有可用更新") {
                        model.addInstance(for: script)
                    } extra: {
                        Button("在 Finder 打开") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: script.directory)])
                        }
                        if script.availableUpdateSHA != nil,
                           let item = model.market.first(where: { $0.manifest.id == script.id && $0.repository == script.sourceRepository }) {
                            Button("更新") { pendingUpdate = item }
                        }
                    }
                }
                if !model.market.isEmpty { Text("仓库脚本").font(.headline) }
                ForEach(model.market) { item in
                    if !model.data.installedScripts.contains(where: { $0.id == item.manifest.id }) {
                        ScriptRow(manifest: item.manifest, detail: item.repository) { pendingInstall = item } extra: { EmptyView() }
                    }
                }
            Text("第三方和本地脚本以当前用户权限执行，可读取本机文件及应用保存的密钥。安装前请确认来源和代码内容。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: 850, alignment: .leading)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { pendingLocal = url }
            else if case .failure(let error) = result { model.statusMessage = error.localizedDescription }
        }
        .confirmationDialog("运行此脚本前，请确认来源可信。", isPresented: Binding(get: { pendingLocal != nil }, set: { if !$0 { pendingLocal = nil } })) {
            Button("导入脚本") {
                if let url = pendingLocal {
                    let access = url.startAccessingSecurityScopedResource()
                    model.importLocal(url)
                    if access { url.stopAccessingSecurityScopedResource() }
                }
                pendingLocal = nil
            }
        }
        .confirmationDialog("脚本将以当前用户权限运行，请确认仓库可信。", isPresented: Binding(get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } })) {
            Button("安装") { if let item = pendingInstall { Task { await model.installMarket(item) } }; pendingInstall = nil }
        }
        .confirmationDialog("更新脚本？本地修改将备份后替换。", isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } })) {
            Button("更新并备份") { if let item = pendingUpdate { Task { await model.updateMarket(item, preserveLocal: false) } }; pendingUpdate = nil }
            Button("保留当前版本", role: .cancel) { pendingUpdate = nil }
        }
    }
}

private struct ScriptRow<Extra: View>: View {
    let manifest: ScriptManifest
    let detail: String
    let action: () -> Void
    @ViewBuilder let extra: () -> Extra
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: manifest.outputType.symbol).foregroundStyle(.blue).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(manifest.name).fontWeight(.medium)
                Text(manifest.description).font(.caption).foregroundStyle(.secondary)
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            extra()
            Button("添加到内容", action: action)
        }
        .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.07)))
    }
}

struct HistoryPage: View {
    @ObservedObject var model: AppModel
    @State private var selectedRecord: RunRecord?
    @State private var showFailuresOnly = false
    private var visibleRecords: [RunRecord] {
        showFailuresOnly ? model.data.records.filter { $0.status == "失败" } : model.data.records
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "运行记录", subtitle: "最近 100 条执行、推送与槽位校验记录 · 点击查看详情")
            HStack {
                Picker("筛选记录", selection: $showFailuresOnly) {
                    Text("全部").tag(false)
                    Text("只看失败").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Spacer()
                Button("复制诊断日志") { model.copyDiagnosticLog() }
                    .disabled(model.data.records.isEmpty)
            }
            if visibleRecords.isEmpty {
                Label(showFailuresOnly ? "没有失败记录" : "暂无运行记录", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            List(visibleRecords) { record in
                Button { selectedRecord = record } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(record.status, systemImage: record.status == "成功" ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(record.status == "成功" ? .green : .red)
                        Text(model.data.installedScripts.first(where: { $0.id == record.scriptID })?.manifest.name ?? record.scriptID)
                            .fontWeight(.medium)
                        Spacer()
                        Text(AppDateFormat.short(record.date)).foregroundStyle(.secondary)
                    }
                    Text("\(record.trigger ?? "脚本执行") · \(record.stage ?? "结果") · \(record.detail)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.vertical, 5)
                }.buttonStyle(.plain)
                    .modifier(QuietNavigationFocus())
            }
            .modifier(QuietNavigationFocus())
            }
        }.padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .sheet(item: $selectedRecord) { record in
                RunDetailSheet(record: record)
            }
    }
}

private struct RunDetailSheet: View {
    let record: RunRecord
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("执行详情").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                detail("脚本", record.scriptID)
                detail("状态", record.status)
                detail("时间", AppDateFormat.detail(record.date))
                detail("触发方式", record.trigger ?? "旧版记录")
                detail("执行阶段", record.stage ?? "未知")
                detail("内容类型", record.outputType?.title ?? "未知")
                detail("耗时", String(format: "%.2f 秒", record.duration))
                if let device = record.deviceID, !device.isEmpty { detail("设备", device) }
                if let key = record.taskKey, !key.isEmpty { detail("内容槽", key) }
            }
            Text(record.status == "失败" ? "错误信息" : "执行结果").font(.headline)
            ScrollView { Text(record.detail).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 80)
                .padding(12)
                .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("复制\(record.status == "失败" ? "错误" : "结果")") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.detail, forType: .string)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 390)
    }
    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

struct SettingsPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageTitle(title: "设置", subtitle: "连接设备并调整 Quote/0 的轮播时间")
                GroupBox("Dot. 连接") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Dot. API 密钥").frame(width: 112, alignment: .leading)
                            SecureField("", text: $model.apiKeyInput)
                                .accessibilityLabel("Dot. API 密钥")
                        }
                        HStack {
                            Button("连接并读取设备") { Task { await model.connect() } }
                            Button("同步内容槽") { Task { await model.syncDevice() } }.disabled(model.data.selectedDeviceID.isEmpty)
                            Spacer()
                        }
                        Picker("Quote/0 设备", selection: Binding(get: { model.data.selectedDeviceID }, set: { model.data.selectedDeviceID = $0; model.persist(); Task { await model.syncDevice() } })) {
                            Text("请选择设备").tag("")
                            ForEach(model.data.devices) { device in Text(device.name).tag(device.id) }
                        }
                        if let slots = model.data.slots[model.data.selectedDeviceID] {
                            Text("循环内容槽：文本 \(slots.filter { $0.type == "TEXT_API" }.count) · 图像 \(slots.filter { $0.type == "IMAGE_API" }.count) · 画板 \(slots.filter { $0.type == "CANVAS_API" }.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }
                GroupBox("设备轮播") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("每隔")
                            TextField("分钟", value: $model.currentIntervalMinutes, format: .number)
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                            Text("分钟切换一次")
                            Menu("常用间隔") {
                                ForEach([1, 5, 10, 15, 30, 60, 120, 360], id: \.self) { minutes in
                                    Button("\(minutes) 分钟") { model.currentIntervalMinutes = minutes }
                                }
                            }
                        }
                        Text("同时设置插电和电池状态；影响设备整个循环列表。每个任务的脚本执行计划在内容页设置。")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.currentIntervalMinutes != model.savedIntervalMinutes {
                            Label("间隔尚未保存到设备", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("设备当前间隔：\(model.savedIntervalMinutes) 分钟")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("保存间隔到设备") { Task { await model.saveInterval() } }
                            .disabled(model.data.selectedDeviceID.isEmpty || !(1...720).contains(model.currentIntervalMinutes) || model.currentIntervalMinutes == model.savedIntervalMinutes)
                    }.padding(8)
                }
                GroupBox("应用") {
                    Toggle("登录后启动 quote0UI", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                        .padding(8)
                }
            }
            .padding(24)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 250/255, green: 250/255, blue: 249/255))
    }
}
