import Foundation
import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var data: AppData
    @Published var market: [MarketScript] = []
    @Published var busy = false
    @Published var statusMessage = "" {
        didSet {
            statusDismissTask?.cancel()
            guard !statusMessage.isEmpty else { return }
            let message = statusMessage
            statusDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                if self?.statusMessage == message { self?.statusMessage = "" }
            }
        }
    }
    @Published var previews: [UUID: ScriptResult] = [:]
    @Published var currentIntervalMinutes: Int = 5
    @Published var savedIntervalMinutes: Int = 5
    @Published var repositoryInput = ""
    @Published var marketLoading = false
    @Published var marketErrors: [String] = []
    @Published var apiKeyInput = ""
    @Published var selectedPage: AppPage = .overview
    @Published var selectedInstanceID: UUID?
    @Published var loginEnabled = false

    let store = LocalStore()
    private let runner = ScriptRunner()
    private let repositories = RepositoryService()
    private var timer: Timer?
    private var statusDismissTask: Task<Void, Never>?
    private var running: Set<UUID> = []
    private var marketRefreshID = UUID()

    init() {
        try? store.prepare()
        data = store.load()
        previews = Dictionary(uniqueKeysWithValues: data.instances.compactMap { instance in
            store.loadPreview(for: instance.id).map { (instance.id, $0) }
        })
        apiKeyInput = data.apiKey
        loginEnabled = SMAppService.mainApp.status == .enabled
        do { try store.prepare(); try installBundledIfNeeded() } catch { statusMessage = error.localizedDescription }
        for index in data.instances.indices where data.instances[index].scriptID == "official.kimi-usage" && !data.instances[index].enabled && data.instances[index].taskKey.isEmpty && data.instances[index].nextRun != nil {
            data.instances[index].nextRun = nil
            data.instances[index].lastStatus = "需重新绑定图像槽"
        }
        for index in data.instances.indices where data.instances[index].enabled && data.instances[index].nextRun == nil {
            data.instances[index].nextRun = Date()
        }
        persist()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runDue() }
        }
        Task { await runDue(); await refreshMarket() }
    }

    private func installBundledIfNeeded() throws {
        guard let root = Bundle.module.resourceURL?.appending(path: "BundledScripts") else { return }
        for name in ["demo-text", "demo-image", "demo-canvas"] {
            let source = root.appending(path: name)
            let manifest = try JSONDecoder().decode(ScriptManifest.self, from: Data(contentsOf: source.appending(path: "script.json")))
            if data.removedBundledScriptIDs?.contains(manifest.id) == true { continue }
            if let index = data.installedScripts.firstIndex(where: { $0.id == manifest.id }) {
                guard data.installedScripts[index].sourceRepository == nil,
                      data.installedScripts[index].manifest.version != manifest.version else { continue }
                let installed = data.installedScripts[index]
                let old = URL(fileURLWithPath: installed.directory)
                let backup = store.root.appending(path: "backups/\(manifest.id)-\(Int(Date().timeIntervalSince1970))")
                try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: old, to: backup)
                do { try FileManager.default.copyItem(at: source, to: old) }
                catch { try? FileManager.default.moveItem(at: backup, to: old); throw error }
                data.installedScripts[index].manifest = manifest
                for taskIndex in data.instances.indices where data.instances[taskIndex].scriptID == manifest.id {
                    let taskID = data.instances[taskIndex].id
                    previews.removeValue(forKey: taskID)
                    store.deletePreview(for: taskID)
                    for parameter in manifest.parameters where data.instances[taskIndex].parameters[parameter.key] == nil {
                        if let value = parameter.defaultValue { data.instances[taskIndex].parameters[parameter.key] = value }
                        else if parameter.required {
                            data.instances[taskIndex].enabled = false
                            data.instances[taskIndex].nextRun = nil
                            data.instances[taskIndex].lastStatus = "需配置：\(parameter.label)"
                        }
                    }
                }
                if installed.manifest.outputType != manifest.outputType {
                    for taskIndex in data.instances.indices where data.instances[taskIndex].scriptID == manifest.id {
                        data.instances[taskIndex].enabled = false
                        data.instances[taskIndex].taskKey = ""
                        data.instances[taskIndex].nextRun = nil
                        data.instances[taskIndex].lastStatus = "需重新绑定\(manifest.outputType.title)槽"
                    }
                    statusMessage = "\(manifest.name)输出类型已变更；请重新选择\(manifest.outputType.title)槽并启用任务。旧脚本已备份。"
                } else {
                    statusMessage = "\(manifest.name)已更新，任务配置已保留。旧脚本已备份。"
                }
            } else {
                data.installedScripts.append(try store.importScript(from: source))
            }
        }
    }

    func persist() {
        do { try store.save(data) } catch { statusMessage = "保存设置失败：\(error.localizedDescription)" }
    }

    func saveAPIKey() {
        data.apiKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func connect() async {
        saveAPIKey(); busy = true; defer { busy = false }
        do {
            data.devices = try await DotAPIClient(apiKey: data.apiKey).devices().filter { $0.model == "quote_0" }
            if !data.devices.contains(where: { $0.id == data.selectedDeviceID }) { data.selectedDeviceID = data.devices.first?.id ?? "" }
            persist()
            if !data.selectedDeviceID.isEmpty { await syncDevice() }
            statusMessage = data.devices.isEmpty ? "账号下没有 Quote/0 设备" : "已连接 \(data.devices.count) 台 Quote/0"
        } catch { statusMessage = error.localizedDescription }
    }

    func syncDevice() async {
        let id = data.selectedDeviceID
        guard !id.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            let client = DotAPIClient(apiKey: data.apiKey)
            let slots = try await client.slots(deviceID: id)
            data.slots[id] = slots
            let invalidated = data.reconcileBindings(deviceID: id, with: slots)
            recordInvalidatedBindings(invalidated)
            if let settings = try? await client.settings(deviceID: id), let power = settings.interval?.powerMs {
                currentIntervalMinutes = power / 60_000
                savedIntervalMinutes = currentIntervalMinutes
            }
            persist()
            statusMessage = invalidated.isEmpty
                ? "已同步 \(slots.count) 个循环内容槽"
                : "已同步 \(slots.count) 个循环内容槽；\(invalidated.count) 个旧绑定已失效并暂停，请重新选择"
        } catch { statusMessage = error.localizedDescription }
    }

    func saveInterval() async {
        guard !data.selectedDeviceID.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            try await DotAPIClient(apiKey: data.apiKey).updateInterval(deviceID: data.selectedDeviceID, minutes: currentIntervalMinutes)
            savedIntervalMinutes = currentIntervalMinutes
            statusMessage = "设备轮播间隔已更新"
        } catch { statusMessage = error.localizedDescription }
    }

    func setLoginEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            statusMessage = loginEnabled ? "已开启登录后启动" : "已关闭登录后启动"
        } catch { statusMessage = error.localizedDescription }
    }

    func addRepository() {
        do {
            let normalized = try GitHubRepository(repositoryInput).url
            if !data.repositories.contains(normalized) { data.repositories.append(normalized) }
            repositoryInput = ""
            persist()
            Task { await refreshMarket() }
        } catch { statusMessage = error.localizedDescription }
    }

    func removeRepository(_ url: String) {
        data.repositories.removeAll { $0 == url }
        market.removeAll { $0.repository == url }
        persist()
        Task { await refreshMarket() }
    }

    func refreshMarket() async {
        let refreshID = UUID()
        marketRefreshID = refreshID
        marketLoading = !data.repositories.isEmpty
        marketErrors = []
        guard !data.repositories.isEmpty else { market = []; return }
        var all: [MarketScript] = []
        var errors: [String] = []
        for url in data.repositories {
            do { all += try await repositories.browse(url) }
            catch { errors.append("\(url)：\(error.localizedDescription)") }
        }
        guard marketRefreshID == refreshID else { return }
        market = all
        marketErrors = errors
        marketLoading = false
        for index in data.installedScripts.indices {
            data.installedScripts[index].availableUpdateSHA = nil
            guard let source = data.installedScripts[index].sourceRepository,
                  let newer = all.first(where: { $0.repository == source && $0.manifest.id == data.installedScripts[index].id }),
                  newer.sha != data.installedScripts[index].sourceSHA else { continue }
            data.installedScripts[index].availableUpdateSHA = newer.sha
        }
        persist()
    }

    func restoreBundledScripts() {
        data.removedBundledScriptIDs = nil
        do {
            try installBundledIfNeeded()
            persist()
            statusMessage = "已恢复内置示例脚本"
        } catch { statusMessage = error.localizedDescription }
    }

    func deleteScript(_ id: String) {
        guard let script = data.installedScripts.first(where: { $0.id == id }) else { return }
        let related = data.instances.filter { $0.scriptID == id }
        guard !related.contains(where: { running.contains($0.id) }) else {
            statusMessage = "脚本正在运行，请稍后再删除"
            return
        }
        do { try store.deleteScript(script) }
        catch { statusMessage = "删除脚本失败：\(error.localizedDescription)"; return }
        for instance in related {
            previews.removeValue(forKey: instance.id)
            store.deletePreview(for: instance.id)
            try? FileManager.default.removeItem(at: store.root.appending(path: "assets/\(instance.id.uuidString)"))
        }
        data.removeInstalledScript(id)
        if ["official.demo-text", "official.demo-image", "official.demo-canvas"].contains(id) {
            data.removedBundledScriptIDs = (data.removedBundledScriptIDs ?? []).union([id])
        }
        if let selectedInstanceID, !data.instances.contains(where: { $0.id == selectedInstanceID }) {
            self.selectedInstanceID = data.instances.first?.id
        }
        persist()
        statusMessage = "已删除“\(script.manifest.name)”及其 \(related.count) 个内容任务"
    }

    func clearRecords() {
        guard !data.records.isEmpty else { return }
        data.records.removeAll()
        persist()
        statusMessage = "运行记录已清空"
    }

    func importLocal(_ directory: URL) {
        do {
            let script = try store.importScript(from: directory)
            data.installedScripts.append(script)
            persist()
            statusMessage = "已导入 \(script.manifest.name)"
        } catch { statusMessage = error.localizedDescription }
    }

    func installMarket(_ item: MarketScript) async {
        busy = true; defer { busy = false }
        do {
            let script = try await repositories.install(item, store: store)
            data.installedScripts.append(script)
            persist()
            statusMessage = "已安装 \(script.manifest.name)"
        } catch { statusMessage = error.localizedDescription }
    }

    func updateMarket(_ item: MarketScript, preserveLocal: Bool = true) async {
        guard let index = data.installedScripts.firstIndex(where: { $0.id == item.manifest.id }) else { return }
        busy = true; defer { busy = false }
        do {
            data.installedScripts[index] = try await repositories.update(item, current: data.installedScripts[index], store: store, preserveLocal: preserveLocal)
            persist()
            statusMessage = "已更新 \(item.manifest.name)，原版本已备份"
        } catch { statusMessage = error.localizedDescription }
    }

    func addInstance(for script: InstalledScript) {
        var parameters: [String: JSONValue] = [:]
        for parameter in script.manifest.parameters { if let value = parameter.defaultValue { parameters[parameter.key] = value } }
        var instance = ScriptInstance(scriptID: script.id, parameters: parameters)
        instance.deviceID = data.selectedDeviceID
        data.instances.append(instance)
        selectedInstanceID = instance.id
        selectedPage = .content
        persist()
    }

    func updateInstance(_ id: UUID, _ update: (inout ScriptInstance) -> Void) {
        guard let index = data.instances.firstIndex(where: { $0.id == id }) else { return }
        let previous = data.instances[index]
        update(&data.instances[index])
        if previous.parameters != data.instances[index].parameters {
            previews.removeValue(forKey: id)
            store.deletePreview(for: id)
            data.instances[index].lastStatus = "配置已更改，待测试"
        }
        if previous.deviceID != data.instances[index].deviceID { data.instances[index].taskKey = "" }
        if data.instances[index].taskKey.isEmpty { data.instances[index].enabled = false }
        if !data.instances[index].enabled { data.instances[index].nextRun = nil }
        else if previous.schedule != data.instances[index].schedule || !previous.enabled {
            data.instances[index].nextRun = data.instances[index].schedule.next(after: Date())
        }
        let current = data.instances[index]
        if !current.taskKey.isEmpty && data.instances.contains(where: { $0.id != id && $0.deviceID == current.deviceID && $0.taskKey == current.taskKey }) {
            data.instances[index] = previous
            statusMessage = "此内容槽已绑定其他脚本任务"
            return
        }
        persist()
    }

    @discardableResult func assignSlot(_ taskKey: String, to instanceID: UUID, replacing: Bool = false) -> Bool {
        do {
            let deviceID = data.instances.first { $0.id == instanceID }?.deviceID ?? ""
            let owner = taskKey.isEmpty ? nil : data.slotOwner(deviceID: deviceID, taskKey: taskKey, excluding: instanceID)
            try data.assignSlot(taskKey, to: instanceID, replacing: replacing)
            persist()
            if replacing, let owner {
                let name = data.installedScripts.first { $0.id == owner.scriptID }?.manifest.name ?? owner.scriptID
                statusMessage = "已从“\(name)”转移内容槽；旧任务的定时更新已关闭"
            }
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func replaceSlot(_ taskKey: String, deviceID: String, ownerID: UUID, with targetID: UUID) async {
        guard let target = data.instances.first(where: { $0.id == targetID }),
              let script = data.installedScripts.first(where: { $0.id == target.scriptID }) else { return }
        if let missing = missingConfiguration(for: target, script: script) {
            let ownerName = data.instances.first(where: { $0.id == ownerID })
                .flatMap { owner in data.installedScripts.first(where: { $0.id == owner.scriptID })?.manifest.name } ?? "原任务"
            let detail = "“\(ownerName)”仍在使用此槽位。目标任务“\(script.manifest.name)”\(missing)；请先完成脚本参数，再替换。"
            data.records.insert(RunRecord(scriptID: target.scriptID, status: "失败", detail: detail,
                duration: 0, trigger: "槽位替换", deviceID: deviceID, taskKey: taskKey,
                outputType: script.manifest.outputType, stage: "替换前参数检查"), at: 0)
            data.records = Array(data.records.prefix(100))
            statusMessage = detail
            persist()
            return
        }
        let deadline = Date().addingTimeInterval(45)
        while running.contains(ownerID) || running.contains(targetID) {
            guard Date() < deadline else {
                statusMessage = "相关任务仍在运行，请稍后重试替换"
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let ownerIndex = data.instances.firstIndex(where: { $0.id == ownerID }),
              let targetIndex = data.instances.firstIndex(where: { $0.id == targetID }),
              data.instances[ownerIndex].deviceID == deviceID,
              data.instances[ownerIndex].taskKey == taskKey,
              data.instances[targetIndex].deviceID == deviceID else {
            statusMessage = "内容槽绑定已变化，请重新选择"
            return
        }
        let previousOwner = data.instances[ownerIndex]
        let previousTarget = data.instances[targetIndex]
        guard assignSlot(taskKey, to: targetID, replacing: true) else { return }

        if await run(targetID, push: true, triggerOverride: "槽位替换") {
            if let current = data.instances.first(where: { $0.id == targetID }),
               current.deviceID == deviceID, current.taskKey == taskKey {
                updateInstance(targetID) { $0.enabled = true }
            }
        } else if let currentOwner = data.instances.firstIndex(where: { $0.id == ownerID }),
                  let currentTarget = data.instances.firstIndex(where: { $0.id == targetID }),
                  data.instances[currentOwner].taskKey.isEmpty,
                  data.instances[currentTarget].deviceID == deviceID,
                  data.instances[currentTarget].taskKey == taskKey {
            let failure = data.records.first?.detail ?? "写入失败"
            data.instances[currentOwner].taskKey = previousOwner.taskKey
            data.instances[currentOwner].enabled = previousOwner.enabled
            data.instances[currentOwner].nextRun = previousOwner.nextRun
            data.instances[currentOwner].lastStatus = previousOwner.lastStatus
            data.instances[currentTarget].taskKey = previousTarget.taskKey
            data.instances[currentTarget].enabled = previousTarget.enabled
            data.instances[currentTarget].nextRun = previousTarget.nextRun
            if let recordIndex = data.records.firstIndex(where: { $0.scriptID == previousTarget.scriptID && $0.trigger == "槽位替换" }) {
                data.records[recordIndex].stage = "\(data.records[recordIndex].stage ?? "写入失败") · 已恢复原绑定"
            }
            persist()
            statusMessage = "替换失败，已恢复原绑定：\(failure)"
        }
    }

    func importImage(_ source: URL, for instanceID: UUID, parameterKey: String) {
        do {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let oldPath = data.instances.first(where: { $0.id == instanceID })?.parameters[parameterKey]?.object?["path"]?.string
            let file = try store.importImage(source, for: instanceID)
            updateInstance(instanceID) { instance in
                instance.parameters[parameterKey] = .object([
                    "path": .string(file.path), "filename": .string(source.lastPathComponent), "mode": .string("fill"),
                    "offsetX": .number(0), "offsetY": .number(0)
                ])
            }
            if let oldPath, oldPath.hasPrefix(store.root.appending(path: "assets/\(instanceID.uuidString)").path + "/") {
                try? FileManager.default.removeItem(atPath: oldPath)
            }
        } catch { statusMessage = "导入图片失败：\(error.localizedDescription)" }
    }

    func deleteInstance(_ id: UUID) {
        guard !running.contains(id) else { statusMessage = "任务正在运行，请稍后再删除"; return }
        data.instances.removeAll { $0.id == id }
        previews.removeValue(forKey: id)
        store.deletePreview(for: id)
        try? FileManager.default.removeItem(at: store.root.appending(path: "assets/\(id.uuidString)"))
        if selectedInstanceID == id { selectedInstanceID = data.instances.first?.id }
        persist()
        statusMessage = "内容任务已删除；设备槽保留当前画面，可重新绑定"
    }

    @discardableResult func run(_ id: UUID, push: Bool, immediate: Bool = false, scheduled: Bool = false, triggerOverride: String? = nil) async -> Bool {
        guard !running.contains(id), let index = data.instances.firstIndex(where: { $0.id == id }),
              let script = data.installedScripts.first(where: { $0.id == data.instances[index].scriptID }) else { return false }
        if scheduled && !data.instances[index].enabled { return false }
        running.insert(id)
        defer { running.remove(id) }
        let instance = data.instances[index]
        let start = Date()
        var stage = "参数校验"
        var succeeded = false
        do {
            if let missing = missingConfiguration(for: instance, script: script) { throw AppError.message(missing) }
            stage = "脚本执行与结果校验"
            let result = try await runner.run(script, parameters: instance.parameters)
            previews[id] = result
            try? store.savePreview(result, for: id)
            if push {
                stage = "设备内容槽校验与写入"
                guard !instance.deviceID.isEmpty, !instance.taskKey.isEmpty else { throw AppError.message("请先选择设备和内容槽") }
                guard let current = data.instances.first(where: { $0.id == id }),
                      current.deviceID == instance.deviceID, current.taskKey == instance.taskKey else {
                    throw AppError.message("任务绑定已变更，未推送旧结果")
                }
                let slots = try await DotAPIClient(apiKey: data.apiKey).slots(deviceID: instance.deviceID)
                data.slots[instance.deviceID] = slots
                let invalidated = data.reconcileBindings(deviceID: instance.deviceID, with: slots)
                recordInvalidatedBindings(invalidated)
                guard slots.contains(where: { $0.key == instance.taskKey && $0.type == script.manifest.outputType.slotType }) else {
                    throw AppError.message("设备端已移除此内容槽，任务已暂停，请重新选择")
                }
                guard let current = data.instances.first(where: { $0.id == id }),
                      current.deviceID == instance.deviceID, current.taskKey == instance.taskKey else {
                    throw AppError.message("任务绑定已变更，未推送旧结果")
                }
                try await DotAPIClient(apiKey: data.apiKey).send(result: result, directory: URL(fileURLWithPath: script.directory), deviceID: instance.deviceID, taskKey: instance.taskKey, refreshNow: immediate)
            }
            record(instance: instance, script: script, status: "成功", detail: push ? (immediate ? "已请求立即显示" : "内容已保存到设备槽") : "测试成功，未推送", stage: push ? "设备写入完成" : "脚本测试完成", trigger: triggerOverride ?? (scheduled ? "定时运行" : (push ? "手动更新" : "手动测试")), started: start)
            succeeded = true
        } catch {
            record(instance: instance, script: script, status: "失败", detail: redacted(error.localizedDescription, using: instance.parameters), stage: stage, trigger: triggerOverride ?? (scheduled ? "定时运行" : (push ? "手动更新" : "手动测试")), started: start)
        }
        if let current = data.instances.firstIndex(where: { $0.id == id }) {
            data.instances[current].lastRun = Date()
            if scheduled {
                data.instances[current].nextRun = data.instances[current].enabled && !data.instances[current].taskKey.isEmpty
                    ? data.instances[current].schedule.next(after: Date()) : nil
            }
            if !data.instances[current].taskKey.isEmpty || instance.taskKey.isEmpty {
                data.instances[current].lastStatus = data.records.first?.status
            }
        }
        persist()
        return succeeded
    }

    private func missingConfiguration(for instance: ScriptInstance, script: InstalledScript) -> String? {
        for parameter in script.manifest.parameters where parameter.required {
            let value = instance.parameters[parameter.key]
            if parameter.type == "image" {
                guard let path = value?.object?["path"]?.string,
                      !path.isEmpty, FileManager.default.isReadableFile(atPath: path) else {
                    return "尚未选择“\(parameter.label)”图片"
                }
            } else if parameter.type == "boolean" {
                guard case .some(.bool) = value else { return "尚未配置“\(parameter.label)”" }
            } else if parameter.type == "number" {
                guard case .some(.number) = value else { return "尚未配置“\(parameter.label)”" }
            } else if value?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return "尚未填写“\(parameter.label)”"
            }
        }
        return nil
    }

    private func recordInvalidatedBindings(_ instances: [ScriptInstance]) {
        for instance in instances {
            let outputType = data.installedScripts.first(where: { $0.id == instance.scriptID })?.manifest.outputType
            data.records.insert(RunRecord(scriptID: instance.scriptID, status: "失败",
                detail: "设备端内容槽已删除或类型变更；原绑定已解除，定时更新已暂停，请重新选择内容槽。",
                duration: 0, trigger: "槽位同步", deviceID: instance.deviceID,
                taskKey: instance.taskKey, outputType: outputType, stage: "槽位校验"), at: 0)
        }
        data.records = Array(data.records.prefix(100))
    }

    func copyDiagnosticLog() {
        let lines = data.records.map { record in
            let name = data.installedScripts.first(where: { $0.id == record.scriptID })?.manifest.name ?? record.scriptID
            let parameters = data.instances.first(where: { $0.scriptID == record.scriptID })?.parameters ?? [:]
            let detail = redacted(record.detail, using: parameters)
            let slot = record.taskKey.map { String($0.suffix(6)) } ?? "无"
            return "\(AppDateFormat.detail(record.date)) | \(name) | \(record.status) | \(record.trigger ?? "未知触发") | \(record.stage ?? "未知阶段") | 槽位…\(slot) | \(detail)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        statusMessage = "已复制最近 \(lines.count) 条诊断记录"
    }

    private func redacted(_ text: String, using values: [String: JSONValue]) -> String {
        var result = text
        for value in values.values.compactMap(\.string) where value.count > 4 { result = result.replacingOccurrences(of: value, with: "••••") }
        if !data.apiKey.isEmpty { result = result.replacingOccurrences(of: data.apiKey, with: "••••") }
        return result
    }

    private func record(instance: ScriptInstance, script: InstalledScript, status: String, detail: String, stage: String, trigger: String, started: Date) {
        data.records.insert(RunRecord(scriptID: script.id, status: status, detail: detail, duration: Date().timeIntervalSince(started), trigger: trigger, deviceID: instance.deviceID, taskKey: instance.taskKey, outputType: script.manifest.outputType, stage: stage), at: 0)
        data.records = Array(data.records.prefix(100))
        statusMessage = detail
    }

    private func runDue() async {
        guard !data.paused else { return }
        let due = data.instances.filter { $0.enabled && ($0.nextRun ?? .distantPast) <= Date() && !running.contains($0.id) }
        for instance in due { await run(instance.id, push: true, scheduled: true) }
    }
}

enum AppPage: String, CaseIterable, Identifiable {
    case overview = "设备概览", content = "内容", market = "脚本市场", history = "运行记录", settings = "设置"
    var id: Self { self }
    var symbol: String { switch self { case .overview: "rectangle.3.group"; case .content: "rectangle.stack"; case .market: "square.stack.3d.up"; case .history: "clock.arrow.circlepath"; case .settings: "gearshape" } }
}
