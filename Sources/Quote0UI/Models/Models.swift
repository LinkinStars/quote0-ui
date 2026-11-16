import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try box.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .object(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .null: try box.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

enum OutputType: String, Codable, CaseIterable, Sendable {
    case text, image, canvas
    var slotType: String { "\(rawValue.uppercased())_API" }
    var title: String { switch self { case .text: "文本"; case .image: "图像"; case .canvas: "画板" } }
    var symbol: String { switch self { case .text: "text.alignleft"; case .image: "photo"; case .canvas: "square.on.square" } }
}

struct ScriptParameter: Codable, Identifiable, Sendable {
    let key: String
    let label: String
    let type: String
    var required: Bool = false
    var defaultValue: JSONValue?
    var options: [String]?
    var id: String { key }

    enum CodingKeys: String, CodingKey { case key, label, type, required, defaultValue = "default", options }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        key = try box.decode(String.self, forKey: .key)
        label = try box.decode(String.self, forKey: .label)
        type = try box.decode(String.self, forKey: .type)
        required = try box.decodeIfPresent(Bool.self, forKey: .required) ?? false
        defaultValue = try box.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
        options = try box.decodeIfPresent([String].self, forKey: .options)
    }
}

struct ScriptManifest: Codable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let description: String
    let entrypoint: String
    let outputType: OutputType
    var requirements: [String] = []
    var parameters: [ScriptParameter] = []

    init(schemaVersion: Int, id: String, name: String, version: String, description: String, entrypoint: String, outputType: OutputType, requirements: [String] = [], parameters: [ScriptParameter] = []) {
        self.schemaVersion = schemaVersion; self.id = id; self.name = name; self.version = version
        self.description = description; self.entrypoint = entrypoint; self.outputType = outputType
        self.requirements = requirements; self.parameters = parameters
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, name, version, description, entrypoint, outputType, requirements, parameters }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decode(Int.self, forKey: .schemaVersion)
        id = try box.decode(String.self, forKey: .id)
        name = try box.decode(String.self, forKey: .name)
        version = try box.decode(String.self, forKey: .version)
        description = try box.decodeIfPresent(String.self, forKey: .description) ?? ""
        entrypoint = try box.decode(String.self, forKey: .entrypoint)
        outputType = try box.decode(OutputType.self, forKey: .outputType)
        requirements = try box.decodeIfPresent([String].self, forKey: .requirements) ?? []
        parameters = try box.decodeIfPresent([ScriptParameter].self, forKey: .parameters) ?? []
    }

    func validate() throws {
        guard schemaVersion == 1, !id.isEmpty, !name.isEmpty, !version.isEmpty else { throw AppError.message("脚本清单版本或必填字段无效") }
        let allowedID = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard id != ".", id != "..", id.unicodeScalars.allSatisfy({ allowedID.contains($0) }) else {
            throw AppError.message("脚本 ID 只能包含英文字母、数字、点、横线和下划线")
        }
        guard !entrypoint.hasPrefix("/"), !entrypoint.split(separator: "/").contains(".."), !entrypoint.isEmpty else { throw AppError.message("脚本入口必须位于脚本目录内") }
        guard Set(parameters.map(\.key)).count == parameters.count else { throw AppError.message("脚本参数名称重复") }
        guard parameters.allSatisfy({ ["string", "multiline", "secret", "number", "boolean", "enum", "image"].contains($0.type) }) else { throw AppError.message("脚本参数类型不受支持") }
    }
}

struct ScriptResult: Codable, Sendable {
    let protocolVersion: Int
    let type: OutputType
    let content: [String: JSONValue]

    func validate(for manifest: ScriptManifest, directory: URL) throws {
        guard protocolVersion == 1, type == manifest.outputType else { throw AppError.message("脚本输出协议或类型与清单不一致") }
        switch type {
        case .text:
            let fields = ["title", "message", "signature"]
            guard fields.contains(where: { !(content[$0]?.string ?? "").isEmpty }) else { throw AppError.message("文本内容为空") }
            for field in fields where content[field] != nil && content[field]?.string == nil { throw AppError.message("\(field) 必须是文本") }
            if let icon = content["icon"]?.string, icon.hasPrefix("data:image/png;base64,") {
                guard let data = Data(base64Encoded: String(icon.dropFirst("data:image/png;base64,".count))), data.count <= 1_000_000 else { throw AppError.message("图标不是有效 PNG 或超过 1 MB") }
            }
        case .image:
            let image = content["image"]?.string
            let file = content["imageFile"]?.string
            guard (image != nil) != (file != nil) else { throw AppError.message("图像结果需要且只能有 image 或 imageFile") }
            if let file {
                let url = URL(fileURLWithPath: file, relativeTo: directory).standardizedFileURL
                guard let data = try? Data(contentsOf: url), data.count <= 3_000_000, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { throw AppError.message("图像文件不是有效 PNG 或超过 3 MB") }
            }
        case .canvas:
            guard content["data"]?.object != nil, let layers = content["windowData"]?.object?["default"]?.array, !layers.isEmpty else { throw AppError.message("画板缺少 data 或 windowData.default") }
        }
    }

    func payload(directory: URL, taskKey: String, refreshNow: Bool) throws -> [String: JSONValue] {
        var value = content
        if type == .image, let file = value.removeValue(forKey: "imageFile")?.string {
            let url = URL(fileURLWithPath: file, relativeTo: directory).standardizedFileURL
            let data = try Data(contentsOf: url)
            value["image"] = .string("data:image/png;base64," + data.base64EncodedString())
        }
        value["taskType"] = .string("loop")
        value["taskKey"] = .string(taskKey)
        value["refreshNow"] = .bool(refreshNow)
        return value
    }
}

struct DotDevice: Codable, Identifiable, Sendable {
    let id: String
    let alias: String?
    let location: String?
    let series: String?
    let model: String
    let edition: Int?
    var name: String { alias?.isEmpty == false ? alias! : id }
}

struct DotSlot: Codable, Identifiable, Sendable {
    let type: String
    let key: String?
    var id: String { key ?? UUID().uuidString }
}

struct DotSettings: Codable, Sendable {
    var interval: Interval?
    struct Interval: Codable, Sendable { var powerMs: Int?; var batteryMs: Int? }
}

enum RunSchedule: Codable, Equatable, Sendable {
    case interval(Int)
    case daily(hour: Int, minute: Int)

    func next(after date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .interval(let minutes): return date.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        case .daily(let hour, let minute):
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) ?? date.addingTimeInterval(86400)
        }
    }
}

struct ScriptInstance: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var scriptID: String
    var deviceID: String = ""
    var taskKey: String = ""
    var parameters: [String: JSONValue] = [:]
    var schedule: RunSchedule = .interval(30)
    var enabled: Bool = false
    var nextRun: Date?
    var lastRun: Date?
    var lastStatus: String?
}

struct InstalledScript: Codable, Identifiable, Sendable {
    var id: String { manifest.id }
    var manifest: ScriptManifest
    var directory: String
    var sourceRepository: String?
    var sourcePath: String?
    var sourceSHA: String?
    var installedHash: String?
    var availableUpdateSHA: String?
}

struct RunRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var scriptID: String
    var status: String
    var detail: String
    var duration: Double
    var trigger: String? = nil
    var deviceID: String? = nil
    var taskKey: String? = nil
    var outputType: OutputType? = nil
    var stage: String? = nil
}

struct AppData: Codable, Sendable {
    static let officialRepositoryURL = "https://github.com/LinkinStars/quote0-ui?ref=main&path=ScriptCatalog"
    var apiKey: String = ""
    var selectedDeviceID: String = ""
    var devices: [DotDevice] = []
    var slots: [String: [DotSlot]] = [:]
    var installedScripts: [InstalledScript] = []
    var instances: [ScriptInstance] = []
    var repositories: [String] = [officialRepositoryURL]
    var records: [RunRecord] = []
    var paused: Bool = false
    var marketCatalogMigrationVersion: Int? = 1
    var removedBundledScriptIDs: Set<String>? = nil

    @discardableResult mutating func removeInstalledScript(_ id: String) -> [ScriptInstance] {
        let removed = instances.filter { $0.scriptID == id }
        instances.removeAll { $0.scriptID == id }
        installedScripts.removeAll { $0.id == id }
        return removed
    }

    func slotOwner(deviceID: String, taskKey: String, excluding instanceID: UUID) -> ScriptInstance? {
        instances.first { $0.id != instanceID && $0.deviceID == deviceID && $0.taskKey == taskKey }
    }

    @discardableResult mutating func reconcileBindings(deviceID: String, with currentSlots: [DotSlot]) -> [ScriptInstance] {
        var invalidated: [ScriptInstance] = []
        for index in instances.indices where instances[index].deviceID == deviceID && !instances[index].taskKey.isEmpty {
            let instance = instances[index]
            let expectedType = installedScripts.first { $0.id == instance.scriptID }?.manifest.outputType.slotType
            guard currentSlots.contains(where: { $0.key == instance.taskKey && $0.type == expectedType }) else {
                invalidated.append(instance)
                instances[index].taskKey = ""
                instances[index].enabled = false
                instances[index].nextRun = nil
                instances[index].lastStatus = "原内容槽已从设备端移除，请重新选择"
                continue
            }
        }
        return invalidated
    }

    mutating func assignSlot(_ taskKey: String, to instanceID: UUID, replacing: Bool = false) throws {
        guard let target = instances.firstIndex(where: { $0.id == instanceID }) else { return }
        let deviceID = instances[target].deviceID
        if !taskKey.isEmpty, let owner = instances.firstIndex(where: { $0.id != instanceID && $0.deviceID == deviceID && $0.taskKey == taskKey }) {
            guard replacing else { throw AppError.message("此内容槽已被其他脚本任务使用") }
            instances[owner].enabled = false
            instances[owner].taskKey = ""
            instances[owner].nextRun = nil
            instances[owner].lastStatus = "内容槽已转给其他任务，定时更新已关闭"
        }
        instances[target].taskKey = taskKey
        if taskKey.isEmpty {
            instances[target].enabled = false
            instances[target].nextRun = nil
        }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}
