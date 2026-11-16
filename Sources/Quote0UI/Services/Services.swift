import Foundation
import Darwin
import AppKit

struct DotAPIClient: Sendable {
    let apiKey: String
    private let base = URL(string: "https://dot.mindreset.tech/api/authV2/open")!

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        guard !apiKey.isEmpty else { throw AppError.message("请先填写 Dot. API 密钥") }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("Dot. API 未返回 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["message"]?.string ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let retry = http.value(forHTTPHeaderField: "Retry-After").map { "；请在 \($0) 秒后重试" } ?? ""
            throw AppError.message("Dot. API \(http.statusCode)：\(detail)\(retry)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func devices() async throws -> [DotDevice] { try await request("devices") }
    func slots(deviceID: String) async throws -> [DotSlot] { try await request("device/\(deviceID)/loop/list") }
    func settings(deviceID: String) async throws -> DotSettings { try await request("device/\(deviceID)/settings") }
    func updateInterval(deviceID: String, minutes: Int) async throws {
        guard (1...720).contains(minutes) else { throw AppError.message("轮播间隔必须在 1 分钟到 12 小时之间") }
        let body: [String: JSONValue] = ["interval": .object(["powerMs": .number(Double(minutes * 60_000)), "batteryMs": .number(Double(minutes * 60_000))])]
        let _: [String: JSONValue] = try await request("device/\(deviceID)/settings", method: "POST", body: JSONEncoder().encode(body))
    }
    func send(result: ScriptResult, directory: URL, deviceID: String, taskKey: String, refreshNow: Bool) async throws {
        let body = try JSONEncoder().encode(result.payload(directory: directory, taskKey: taskKey, refreshNow: refreshNow))
        let _: [String: JSONValue] = try await request("device/\(deviceID)/\(result.type.rawValue)", method: "POST", body: body)
    }
}

struct LocalStore: Sendable {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "quote0UI")
    }
    var stateURL: URL { root.appending(path: "state.json") }
    var scriptsURL: URL { root.appending(path: "scripts") }
    var previewsURL: URL { root.appending(path: "previews") }

    func prepare() throws {
        let previous = root.deletingLastPathComponent().appending(path: "Quote0")
        if root.lastPathComponent == "quote0UI", !FileManager.default.fileExists(atPath: root.path), FileManager.default.fileExists(atPath: previous.path) {
            try FileManager.default.moveItem(at: previous, to: root)
        }
        try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
    }
    func load() -> AppData {
        guard let data = try? Data(contentsOf: stateURL), var value = try? JSONDecoder().decode(AppData.self, from: data) else { return AppData() }
        if value.marketCatalogMigrationVersion == nil {
            func isOldRepository(_ url: String) -> Bool {
                guard let repository = try? GitHubRepository(url) else { return false }
                return repository.owner.lowercased() == "linkinstars" && repository.name == "quote0-scripts" && repository.basePath.isEmpty
            }
            value.repositories = value.repositories.map { isOldRepository($0) ? AppData.officialRepositoryURL : $0 }
            value.repositories = value.repositories.reduce(into: []) { result, url in
                if !result.contains(url) { result.append(url) }
            }
            if value.repositories.isEmpty { value.repositories = [AppData.officialRepositoryURL] }
            for index in value.installedScripts.indices where value.installedScripts[index].sourceRepository.map(isOldRepository) == true {
                value.installedScripts[index].sourceRepository = AppData.officialRepositoryURL
                if let path = value.installedScripts[index].sourcePath {
                    value.installedScripts[index].sourcePath = "ScriptCatalog/" + path
                }
            }
            value.marketCatalogMigrationVersion = 1
        }
        for index in value.installedScripts.indices {
            let oldPath = value.installedScripts[index].directory
            if oldPath.hasPrefix(root.deletingLastPathComponent().appending(path: "Quote0").path + "/") {
                value.installedScripts[index].directory = root.path + oldPath.dropFirst(root.deletingLastPathComponent().appending(path: "Quote0").path.count)
            }
        }
        value.records = Array(value.records.prefix(100))
        return value
    }
    func save(_ value: AppData) throws {
        try prepare()
        let data = try JSONEncoder().encode(value)
        try data.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    func loadPreview(for id: UUID) -> ScriptResult? {
        guard let data = try? Data(contentsOf: previewsURL.appending(path: "\(id.uuidString).json")) else { return nil }
        return try? JSONDecoder().decode(ScriptResult.self, from: data)
    }
    func savePreview(_ result: ScriptResult, for id: UUID) throws {
        try FileManager.default.createDirectory(at: previewsURL, withIntermediateDirectories: true)
        let file = previewsURL.appending(path: "\(id.uuidString).json")
        try JSONEncoder().encode(result).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func deletePreview(for id: UUID) {
        try? FileManager.default.removeItem(at: previewsURL.appending(path: "\(id.uuidString).json"))
    }
    func importImage(_ source: URL, for instanceID: UUID) throws -> URL {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 20_000_000,
              let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              bitmap.pixelsWide * bitmap.pixelsHigh <= 30_000_000,
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.message("请选择 20 MB 以内的有效图片")
        }
        let directory = root.appending(path: "assets/\(instanceID.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let target = directory.appending(path: UUID().uuidString + ".png")
        try png.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }
    func importScript(from directory: URL) throws -> InstalledScript {
        try prepare()
        let manifest = try JSONDecoder().decode(ScriptManifest.self, from: Data(contentsOf: directory.appending(path: "script.json")))
        try manifest.validate()
        let entry = directory.appending(path: manifest.entrypoint).standardizedFileURL
        guard entry.path.hasPrefix(directory.standardizedFileURL.path + "/"), FileManager.default.isExecutableFile(atPath: entry.path) else { throw AppError.message("脚本入口不存在或不可执行") }
        let target = scriptsURL.appending(path: manifest.id)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw AppError.message("同名脚本已安装") }
        try FileManager.default.copyItem(at: directory, to: target)
        return InstalledScript(manifest: manifest, directory: target.path)
    }

    func deleteScript(_ script: InstalledScript) throws {
        let directory = URL(fileURLWithPath: script.directory).standardizedFileURL
        guard directory.deletingLastPathComponent().path == scriptsURL.standardizedFileURL.path,
              directory.lastPathComponent == script.id else {
            throw AppError.message("脚本目录不在客户端管理范围内，无法删除")
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

struct ScriptRunner: Sendable {
    func run(_ script: InstalledScript, parameters: [String: JSONValue], timeout: TimeInterval = 30) async throws -> ScriptResult {
        try await Task.detached(priority: .userInitiated) {
            let directory = URL(fileURLWithPath: script.directory, isDirectory: true)
            let executable = directory.appending(path: script.manifest.entrypoint).standardizedFileURL
            guard executable.path.hasPrefix(directory.standardizedFileURL.path + "/"), FileManager.default.isExecutableFile(atPath: executable.path) else { throw AppError.message("脚本入口不存在或不可执行") }
            let input = try JSONEncoder().encode(["protocolVersion": JSONValue.number(1), "parameters": .object(parameters)])
            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            let commonPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            environment["PATH"] = (commonPaths + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
            process.environment = environment
            let stdin = Pipe()
            process.standardInput = stdin
            let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let outURL = temp.appending(path: "stdout")
            let errURL = temp.appending(path: "stderr")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: outURL)
            let err = try FileHandle(forWritingTo: errURL)
            defer { try? out.close(); try? err.close() }
            process.standardOutput = out
            process.standardError = err
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning {
                process.terminate()
                let stopDeadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < stopDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                throw AppError.message("脚本运行超过 \(Int(timeout)) 秒")
            }
            let stdout = try Data(contentsOf: outURL)
            let stderr = try Data(contentsOf: errURL)
            guard stdout.count <= 4_000_000, stderr.count <= 200_000 else { throw AppError.message("脚本输出过大") }
            guard process.terminationStatus == 0 else {
                let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppError.message(message.isEmpty ? "脚本退出码 \(process.terminationStatus)" : message)
            }
            let result = try JSONDecoder().decode(ScriptResult.self, from: stdout)
            try result.validate(for: script.manifest, directory: directory)
            return result
        }.value
    }
}
