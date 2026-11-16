import Foundation
import CryptoKit

struct Catalog: Codable, Sendable {
    let schemaVersion: Int
    let scripts: [CatalogEntry]
}
struct CatalogEntry: Codable, Identifiable, Sendable {
    let path: String
    var id: String { path }
}
struct MarketScript: Identifiable, Sendable {
    let manifest: ScriptManifest
    let repository: String
    let path: String
    let ref: String
    let sha: String
    var id: String { repository + "/" + manifest.id }
}

struct GitHubRepository: Sendable {
    let owner: String
    let name: String
    let ref: String?
    let basePath: String
    var url: String {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "github.com"
        parts.path = "/\(owner)/\(name)"
        var query: [URLQueryItem] = []
        if let ref { query.append(URLQueryItem(name: "ref", value: ref)) }
        if !basePath.isEmpty { query.append(URLQueryItem(name: "path", value: basePath)) }
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url!.absoluteString
    }

    func path(_ relative: String) -> String {
        basePath.isEmpty ? relative : basePath + "/" + relative
    }

    init(_ raw: String) throws {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else {
            throw AppError.message("请输入 GitHub 仓库或目录的 HTTPS 地址")
        }
        let segments = parts.path.split(separator: "/").map(String.init)
        guard segments.count == 2 || (segments.count >= 5 && segments[2] == "tree") else {
            throw AppError.message("请输入仓库首页或 /tree/分支/目录 链接")
        }
        let repositoryName = segments[1].hasSuffix(".git") ? String(segments[1].dropLast(4)) : segments[1]
        guard Self.isSafeSegment(segments[0]), Self.isSafeSegment(repositoryName) else { throw AppError.message("GitHub 仓库地址无效") }
        owner = segments[0]
        name = repositoryName
        let requestedRef = parts.queryItems?.first(where: { $0.name == "ref" })?.value
        let requestedPath = parts.queryItems?.first(where: { $0.name == "path" })?.value
        ref = segments.count > 2 ? segments[3] : requestedRef
        basePath = segments.count > 2 ? segments.dropFirst(4).joined(separator: "/") : (requestedPath ?? "")
        guard ref.map({ !$0.isEmpty && !$0.contains("..") }) ?? true,
              Self.isSafePath(basePath) else { throw AppError.message("GitHub 分支或目录路径无效") }
    }

    static func isSafeSegment(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("\\") && !value.contains(":")
    }

    static func isSafePath(_ value: String) -> Bool {
        value.isEmpty || (!value.hasPrefix("/") && !value.hasSuffix("/") && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { isSafeSegment(String($0)) })
    }
}

struct RepositoryService: Sendable {
    private let fetch: @Sendable (String) async throws -> Data

    init(fetch: @escaping @Sendable (String) async throws -> Data = RepositoryService.networkData) {
        self.fetch = fetch
    }

    private struct Tree: Decodable {
        let tree: [TreeEntry]
        let truncated: Bool
    }
    private struct TreeEntry: Decodable {
        let path: String
        let mode: String
        let type: String
        let sha: String
    }
    private struct Blob: Decodable {
        let content: String
        let encoding: String
    }

    private static func networkData(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("quote0UI/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw AppError.message("GitHub 请求失败，请检查仓库地址或稍后重试") }
        return data
    }

    private func apiData(_ path: String) async throws -> Data { try await fetch(path) }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    private func tree(_ sha: String, from repo: GitHubRepository) async throws -> Tree {
        guard sha.count == 40, sha.allSatisfy(\.isHexDigit) else { throw AppError.message("GitHub 版本编号无效") }
        let result = try JSONDecoder().decode(Tree.self, from: await apiData("/repos/\(encoded(repo.owner))/\(encoded(repo.name))/git/trees/\(sha)?recursive=1"))
        guard !result.truncated else { throw AppError.message("GitHub 目录过大，无法完整读取") }
        return result
    }

    private func blob(_ sha: String, from repo: GitHubRepository) async throws -> Data {
        guard sha.count == 40, sha.allSatisfy(\.isHexDigit) else { throw AppError.message("GitHub 文件编号无效") }
        let result = try JSONDecoder().decode(Blob.self, from: await apiData("/repos/\(encoded(repo.owner))/\(encoded(repo.name))/git/blobs/\(sha)"))
        guard result.encoding == "base64", let data = Data(base64Encoded: result.content, options: .ignoreUnknownCharacters) else {
            throw AppError.message("GitHub 文件内容无法读取")
        }
        return data
    }

    func browse(_ raw: String) async throws -> [MarketScript] {
        let repo = try GitHubRepository(raw)
        let ref = encoded(repo.ref ?? "HEAD")
        let commit = try JSONDecoder().decode([String: JSONValue].self, from: await apiData("/repos/\(encoded(repo.owner))/\(encoded(repo.name))/commits/\(ref)"))
        guard let treeSHA = commit["commit"]?.object?["tree"]?.object?["sha"]?.string else { throw AppError.message("GitHub 仓库版本无法读取") }
        let entries = try await tree(treeSHA, from: repo).tree
        guard let catalogFile = entries.first(where: { $0.path == repo.path("catalog.json") && $0.type == "blob" }) else {
            throw AppError.message("目录中缺少 catalog.json")
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: await blob(catalogFile.sha, from: repo))
        guard catalog.schemaVersion == 1 else { throw AppError.message("脚本市场索引版本不受支持") }
        var items: [MarketScript] = []
        for entry in catalog.scripts {
            guard GitHubRepository.isSafePath(entry.path), !entry.path.isEmpty else { continue }
            let scriptPath = repo.path(entry.path)
            guard let directory = entries.first(where: { $0.path == scriptPath && $0.type == "tree" }),
                  let manifestFile = entries.first(where: { $0.path == scriptPath + "/script.json" && $0.type == "blob" }) else { continue }
            do {
                let manifest = try JSONDecoder().decode(ScriptManifest.self, from: await blob(manifestFile.sha, from: repo))
                try manifest.validate()
                items.append(MarketScript(manifest: manifest, repository: repo.url, path: scriptPath, ref: repo.ref ?? "HEAD", sha: directory.sha))
            } catch { continue }
        }
        return items
    }

    func install(_ item: MarketScript, store: LocalStore) async throws -> InstalledScript {
        let repo = try GitHubRepository(item.repository)
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appending(path: "script")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let entries = try await tree(item.sha, from: repo).tree
        guard !entries.isEmpty else { throw AppError.message("脚本目录为空") }
        for entry in entries where entry.type == "blob" {
            guard GitHubRepository.isSafePath(entry.path), !entry.path.isEmpty,
                  entry.mode == "100644" || entry.mode == "100755" else { throw AppError.message("脚本包含不支持的文件") }
            let target = source.appending(path: entry.path).standardizedFileURL
            guard target.path.hasPrefix(source.standardizedFileURL.path + "/") else { throw AppError.message("脚本文件路径无效") }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await blob(entry.sha, from: repo).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: entry.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: target.path)
        }
        guard entries.allSatisfy({ $0.type == "tree" || $0.type == "blob" }) else { throw AppError.message("脚本包含不支持的链接") }
        let downloadedManifest = try JSONDecoder().decode(ScriptManifest.self, from: Data(contentsOf: source.appending(path: "script.json")))
        guard downloadedManifest.id == item.manifest.id else { throw AppError.message("脚本标识与市场列表不一致") }
        var installed = try store.importScript(from: source)
        installed.sourceRepository = item.repository
        installed.sourcePath = item.path
        installed.sourceSHA = item.sha
        installed.installedHash = try directoryHash(URL(fileURLWithPath: installed.directory))
        return installed
    }

    func update(_ item: MarketScript, current: InstalledScript, store: LocalStore, preserveLocal: Bool) async throws -> InstalledScript {
        let existing = URL(fileURLWithPath: current.directory)
        let changed = try directoryHash(existing) != current.installedHash
        if changed && preserveLocal { throw AppError.message("脚本有本地修改；请选择替换并备份，或保留当前版本") }
        let tempRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let tempStore = LocalStore(root: tempRoot)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let downloaded = try await install(item, store: tempStore)
        let backup = store.root.appending(path: "backups/\(current.id)-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: existing, to: backup)
        do { try FileManager.default.copyItem(at: URL(fileURLWithPath: downloaded.directory), to: existing) }
        catch { try? FileManager.default.moveItem(at: backup, to: existing); throw error }
        var result = downloaded
        result.directory = existing.path
        result.installedHash = try directoryHash(existing)
        result.availableUpdateSHA = nil
        return result
    }

    func directoryHash(_ directory: URL) throws -> String {
        let root = directory.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return "" }
        var files: [URL] = []
        while let file = enumerator.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(file) }
        }
        var hash = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(file.path.dropFirst(root.path.count).utf8))
            hash.update(data: try Data(contentsOf: file))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
