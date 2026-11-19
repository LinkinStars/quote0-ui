import XCTest
@testable import Quote0UI

final class ModelTests: XCTestCase {
    func testGitHubMarketFolderURL() throws {
        let folder = try GitHubRepository("https://github.com/LinkinStars/quote0-ui/tree/main/ScriptCatalog")
        XCTAssertEqual(folder.owner, "LinkinStars")
        XCTAssertEqual(folder.name, "quote0-ui")
        XCTAssertEqual(folder.ref, "main")
        XCTAssertEqual(folder.path("scripts/kimi-usage"), "ScriptCatalog/scripts/kimi-usage")
        XCTAssertEqual(try GitHubRepository(folder.url).url, folder.url)
        XCTAssertEqual(try GitHubRepository("https://github.com/LinkinStars/quote0-ui").path("catalog.json"), "catalog.json")
        XCTAssertThrowsError(try GitHubRepository("https://github.com/LinkinStars/quote0-ui?path=../Secrets"))
    }

    func testMarketDownloadsOnlySelectedScriptAndKeepsExecutablePermission() async throws {
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func blob(_ data: Data) throws -> Data { try json(["encoding": "base64", "content": data.base64EncodedString()]) }
        let rootSHA = String(repeating: "a", count: 40)
        let scriptSHA = String(repeating: "b", count: 40)
        let catalogSHA = String(repeating: "c", count: 40)
        let manifestSHA = String(repeating: "d", count: 40)
        let entrySHA = String(repeating: "e", count: 40)
        let manifest = ScriptManifest(schemaVersion: 1, id: "demo.market", name: "Market", version: "1", description: "", entrypoint: "run.sh", outputType: .text)
        let catalog = Catalog(schemaVersion: 1, scripts: [CatalogEntry(path: "scripts/demo")])
        let entry = Data("#!/bin/sh\nprintf '%s\\n' '{\"protocolVersion\":1,\"type\":\"text\",\"content\":{\"message\":\"OK\"}}'\n".utf8)
        let rootTree: [[String: String]] = [
            ["path": "ScriptCatalog/catalog.json", "mode": "100644", "type": "blob", "sha": catalogSHA],
            ["path": "ScriptCatalog/scripts/demo", "mode": "040000", "type": "tree", "sha": scriptSHA],
            ["path": "ScriptCatalog/scripts/demo/script.json", "mode": "100644", "type": "blob", "sha": manifestSHA],
            ["path": "ScriptCatalog/scripts/demo/run.sh", "mode": "100755", "type": "blob", "sha": entrySHA]
        ]
        let scriptTree: [[String: String]] = [
            ["path": "script.json", "mode": "100644", "type": "blob", "sha": manifestSHA],
            ["path": "run.sh", "mode": "100755", "type": "blob", "sha": entrySHA]
        ]
        let apiRoot = "/repos/demo/market"
        let responses: [String: Data] = [
            apiRoot + "/commits/main": try json(["commit": ["tree": ["sha": rootSHA]]]),
            apiRoot + "/git/trees/\(rootSHA)?recursive=1": try json(["tree": rootTree, "truncated": false]),
            apiRoot + "/git/trees/\(scriptSHA)?recursive=1": try json(["tree": scriptTree, "truncated": false]),
            apiRoot + "/git/blobs/\(catalogSHA)": try blob(JSONEncoder().encode(catalog)),
            apiRoot + "/git/blobs/\(manifestSHA)": try blob(JSONEncoder().encode(manifest)),
            apiRoot + "/git/blobs/\(entrySHA)": try blob(entry)
        ]
        let service = RepositoryService(fetch: { path in
            guard let data = responses[path] else { throw AppError.message("Unexpected request: \(path)") }
            return data
        })
        let items = try await service.browse("https://github.com/demo/market/tree/main/ScriptCatalog")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].sha, scriptSHA)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try await service.install(items[0], store: LocalStore(root: root))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: installed.directory).appending(path: "run.sh").path))
        let result = try await ScriptRunner().run(installed, parameters: [:])
        XCTAssertEqual(result.content["message"], .string("OK"))

        let nextScriptSHA = String(repeating: "1", count: 40)
        let nextManifestSHA = String(repeating: "2", count: 40)
        let nextEntrySHA = String(repeating: "3", count: 40)
        let nextManifest = ScriptManifest(schemaVersion: 1, id: manifest.id, name: manifest.name, version: "2", description: "", entrypoint: "run.sh", outputType: .text)
        let nextEntry = Data("#!/bin/sh\nprintf '%s\\n' '{\"protocolVersion\":1,\"type\":\"text\",\"content\":{\"message\":\"NEW\"}}'\n".utf8)
        let updateResponses: [String: Data] = [
            apiRoot + "/git/trees/\(nextScriptSHA)?recursive=1": try json(["tree": [
                ["path": "script.json", "mode": "100644", "type": "blob", "sha": nextManifestSHA],
                ["path": "run.sh", "mode": "100755", "type": "blob", "sha": nextEntrySHA]
            ], "truncated": false]),
            apiRoot + "/git/blobs/\(nextManifestSHA)": try blob(JSONEncoder().encode(nextManifest)),
            apiRoot + "/git/blobs/\(nextEntrySHA)": try blob(nextEntry)
        ]
        let updateService = RepositoryService(fetch: { path in
            guard let data = updateResponses[path] else { throw AppError.message("Unexpected request: \(path)") }
            return data
        })
        let nextItem = MarketScript(manifest: nextManifest, repository: items[0].repository, path: items[0].path, ref: items[0].ref, sha: nextScriptSHA)
        let updated = try await updateService.update(nextItem, current: installed, store: LocalStore(root: root), preserveLocal: false)
        XCTAssertEqual(updated.directory, installed.directory)
        XCTAssertEqual(updated.manifest.version, "2")
        XCTAssertEqual(updated.sourceSHA, nextScriptSHA)
        let newResult = try await ScriptRunner().run(updated, parameters: [:])
        XCTAssertEqual(newResult.content["message"], .string("NEW"), "更新后必须运行新脚本")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "backups").path).count, 1)
    }

    func testOldMarketRepositoryMigratesToCurrentRepository() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(root: root)
        var old = AppData()
        old.repositories = ["https://github.com/LinkinStars/quote0-scripts"]
        old.marketCatalogMigrationVersion = nil
        try store.save(old)
        XCTAssertEqual(store.load().repositories, [AppData.officialRepositoryURL])
    }

    func testCatalogScriptsArePresent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalogRoot = root.appending(path: "ScriptCatalog")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogRoot.appending(path: "catalog.json")))
        XCTAssertEqual(catalog.scripts.count, 1)
        for item in catalog.scripts {
            XCTAssertTrue(FileManager.default.fileExists(atPath: catalogRoot.appending(path: item.path).appending(path: "script.json").path))
        }
    }

    func testBundledScriptsAreAvailableAtRuntime() throws {
        let directory = try XCTUnwrap(Bundle.module.resourceURL?.appending(path: "BundledScripts"))
        for name in ["demo-text", "demo-image", "demo-canvas"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: name).appending(path: "script.json").path))
        }
    }

    func testScriptResultValidation() throws {
        let manifest = ScriptManifest(schemaVersion: 1, id: "test", name: "Test", version: "1", description: "", entrypoint: "run.sh", outputType: .text)
        let result = ScriptResult(protocolVersion: 1, type: .text, content: ["message": .string("Hello")])
        try result.validate(for: manifest, directory: URL(fileURLWithPath: "/tmp"))
    }
    func testScheduleNext() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RunSchedule.interval(5).next(after: date).timeIntervalSince(date), 300)
    }
    func testScriptIDCannotEscapeInstallDirectory() throws {
        let manifest = ScriptManifest(schemaVersion: 1, id: "../outside", name: "Test", version: "1", description: "", entrypoint: "run.sh", outputType: .text)
        XCTAssertThrowsError(try manifest.validate())
    }
    func testImportedExecutableRunsWithParameters() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = ScriptManifest(schemaVersion: 1, id: "test.local", name: "Local", version: "1", description: "", entrypoint: "run.sh", outputType: .text)
        try JSONEncoder().encode(manifest).write(to: source.appending(path: "script.json"))
        let entry = source.appending(path: "run.sh")
        try "#!/bin/sh\nread -r payload\ncase \"$payload\" in *'\"parameters\":{\"sample\":\"value\"}'*) ;; *) exit 2 ;; esac\nprintf '%s\\n' '{\"protocolVersion\":1,\"type\":\"text\",\"content\":{\"message\":\"OK\"}}'\n".write(to: entry, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        let installed = try LocalStore(root: root.appending(path: "data")).importScript(from: source)
        let result = try await ScriptRunner().run(installed, parameters: ["sample": .string("value")])
        XCTAssertEqual(result.content["message"], .string("OK"))
    }

    func testDeletingInstalledScriptRemovesManagedDirectoryOnly() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = ScriptManifest(schemaVersion: 1, id: "test.delete", name: "Delete", version: "1", description: "", entrypoint: "run.sh", outputType: .text)
        try JSONEncoder().encode(manifest).write(to: source.appending(path: "script.json"))
        let entry = source.appending(path: "run.sh")
        try "#!/bin/sh\nexit 0\n".write(to: entry, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        let store = LocalStore(root: root.appending(path: "data"))
        let installed = try store.importScript(from: source)
        try store.deleteScript(installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertThrowsError(try store.deleteScript(InstalledScript(manifest: manifest, directory: source.path)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testRemovedBundledScriptsRemainRemovedAfterReload() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(root: root)
        var data = AppData()
        data.removedBundledScriptIDs = ["official.demo-text"]
        try store.save(data)
        XCTAssertEqual(store.load().removedBundledScriptIDs, ["official.demo-text"])
    }

    func testRemovingScriptAlsoRemovesOnlyItsContentTasks() {
        let first = ScriptManifest(schemaVersion: 1, id: "first", name: "First", version: "1", description: "", entrypoint: "run.sh", outputType: .text)
        let second = ScriptManifest(schemaVersion: 1, id: "second", name: "Second", version: "1", description: "", entrypoint: "run.sh", outputType: .text)
        var data = AppData()
        data.installedScripts = [InstalledScript(manifest: first, directory: "/tmp/first"), InstalledScript(manifest: second, directory: "/tmp/second")]
        data.instances = [ScriptInstance(scriptID: "first"), ScriptInstance(scriptID: "first"), ScriptInstance(scriptID: "second")]
        XCTAssertEqual(data.removeInstalledScript("first").count, 2)
        XCTAssertEqual(data.installedScripts.map(\.id), ["second"])
        XCTAssertEqual(data.instances.map(\.scriptID), ["second"])
    }
    func testBundledDemoScriptsRun() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sampleImage = root.appending(path: "Tests/Quote0UITests/Fixtures/sample.png")
        for (name, type) in [("demo-text", OutputType.text), ("demo-image", .image), ("demo-canvas", .canvas)] {
            let directory = root.appending(path: "Sources/Quote0UI/Resources/BundledScripts/\(name)")
            let manifest = try JSONDecoder().decode(ScriptManifest.self, from: Data(contentsOf: directory.appending(path: "script.json")))
            XCTAssertEqual(manifest.outputType, type)
            let parameters: [String: JSONValue] = switch type {
            case .text: ["message": .string("  固定测试文字\n")]
            case .image: ["picture": .object(["path": .string(sampleImage.path), "mode": .string("fill"), "offsetX": .number(0), "offsetY": .number(0)])]
            case .canvas: [:]
            }
            let result = try await ScriptRunner().run(InstalledScript(manifest: manifest, directory: directory.path), parameters: parameters)
            XCTAssertEqual(result.type, type)
            if type == .text { XCTAssertEqual(result.content["message"], .string("  固定测试文字\n")) }
            if type == .image {
                let encoded = try XCTUnwrap(result.content["image"]?.string)
                XCTAssertTrue(encoded.hasPrefix("data:image/png;base64,"))
                let png = try XCTUnwrap(Data(base64Encoded: String(encoded.dropFirst("data:image/png;base64,".count))))
                XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
                XCTAssertEqual(Array(png[16..<24]), [0, 0, 1, 40, 0, 0, 0, 152])
            }
            if type == .canvas { XCTAssertEqual(result.content["data"]?.object?["title"], .string("Canvas API")) }
        }
    }
    func testImageImportCopiesFileForScript() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Tests/Quote0UITests/Fixtures/sample.png")
        let id = UUID()
        let target = try LocalStore(root: root).importImage(fixture, for: id)
        XCTAssertTrue(target.path.hasPrefix(root.appending(path: "assets/\(id.uuidString)").path + "/"))
        XCTAssertEqual(target.pathExtension, "png")
        XCTAssertEqual(Array(try Data(contentsOf: target).prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }
    func testImageScriptSupportsEveryDisplayMode() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "Sources/Quote0UI/Resources/BundledScripts/demo-image")
        let fixture = root.appending(path: "Tests/Quote0UITests/Fixtures/sample.png")
        let manifest = try JSONDecoder().decode(ScriptManifest.self, from: Data(contentsOf: directory.appending(path: "script.json")))
        let script = InstalledScript(manifest: manifest, directory: directory.path)
        var outputs: [String: Data] = [:]
        for mode in ["fit", "fill", "stretch", "tile"] {
            let result = try await ScriptRunner().run(script, parameters: ["picture": .object([
                "path": .string(fixture.path), "mode": .string(mode),
                "offsetX": .number(0.5), "offsetY": .number(-0.5)
            ])])
            let encoded = try XCTUnwrap(result.content["image"]?.string)
            let png = try XCTUnwrap(Data(base64Encoded: String(encoded.dropFirst("data:image/png;base64,".count))))
            XCTAssertEqual(Array(png[16..<24]), [0, 0, 1, 40, 0, 0, 0, 152], mode)
            outputs[mode] = png
        }
        XCTAssertEqual(Set(outputs.values).count, 4, "四种显示方式应产生不同画面")

        let moved = try await ScriptRunner().run(script, parameters: ["picture": .object([
            "path": .string(fixture.path), "mode": .string("fill"),
            "offsetX": .number(-1), "offsetY": .number(1)
        ])])
        let movedImage = try XCTUnwrap(moved.content["image"]?.string)
        let movedPNG = try XCTUnwrap(Data(base64Encoded: String(movedImage.dropFirst("data:image/png;base64,".count))))
        XCTAssertNotEqual(movedPNG, outputs["fill"], "拖动位置应改变最终画面")
    }
    func testSlotReplacementStopsPreviousTask() throws {
        let first = UUID(), second = UUID()
        var data = AppData()
        data.instances = [
            ScriptInstance(id: first, scriptID: "first", deviceID: "device", taskKey: "slot", enabled: true, nextRun: Date()),
            ScriptInstance(id: second, scriptID: "second", deviceID: "device")
        ]
        XCTAssertThrowsError(try data.assignSlot("slot", to: second))
        XCTAssertEqual(data.instances[0].taskKey, "slot")
        try data.assignSlot("slot", to: second, replacing: true)
        XCTAssertEqual(data.instances[0].taskKey, "")
        XCTAssertFalse(data.instances[0].enabled)
        XCTAssertNil(data.instances[0].nextRun)
        XCTAssertEqual(data.instances[1].taskKey, "slot")
    }
    func testSyncClearsDeletedAndChangedSlotsWithoutAffectingOtherDevices() {
        let text = ScriptManifest(schemaVersion: 1, id: "test.text", name: "Text", version: "1", description: "", entrypoint: "run.sh", outputType: .text)
        let image = ScriptManifest(schemaVersion: 1, id: "test.image", name: "Image", version: "1", description: "", entrypoint: "run.sh", outputType: .image)
        var data = AppData()
        data.installedScripts = [InstalledScript(manifest: text, directory: "/tmp/text"), InstalledScript(manifest: image, directory: "/tmp/image")]
        data.instances = [
            ScriptInstance(scriptID: text.id, deviceID: "one", taskKey: "kept", enabled: true, nextRun: Date()),
            ScriptInstance(scriptID: image.id, deviceID: "one", taskKey: "deleted", enabled: true, nextRun: Date()),
            ScriptInstance(scriptID: text.id, deviceID: "one", taskKey: "changed", enabled: true, nextRun: Date()),
            ScriptInstance(scriptID: text.id, deviceID: "two", taskKey: "other", enabled: true, nextRun: Date())
        ]
        let invalidated = data.reconcileBindings(deviceID: "one", with: [
            DotSlot(type: "TEXT_API", key: "kept"),
            DotSlot(type: "IMAGE_API", key: "changed")
        ])
        XCTAssertEqual(invalidated.map(\.taskKey), ["deleted", "changed"])
        XCTAssertEqual(data.instances[0].taskKey, "kept")
        XCTAssertTrue(data.instances[0].enabled)
        for index in [1, 2] {
            XCTAssertEqual(data.instances[index].taskKey, "")
            XCTAssertFalse(data.instances[index].enabled)
            XCTAssertNil(data.instances[index].nextRun)
            XCTAssertTrue(data.instances[index].lastStatus?.contains("重新选择") == true)
        }
        XCTAssertEqual(data.instances[3].taskKey, "other")
        XCTAssertTrue(data.instances[3].enabled)
    }
    func testChineseDateFormat() {
        let display = AppDateFormat.short(Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(display.contains("年") && display.contains("月") && display.contains("日"))
        XCTAssertFalse(display.contains("Nov"))
    }
    func testHistoryKeepsLatestHundredOnLoad() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(root: root)
        var data = AppData()
        data.records = (0..<105).map { RunRecord(scriptID: "script-\($0)", status: "成功", detail: "", duration: 0) }
        try store.save(data)
        let loaded = store.load()
        XCTAssertEqual(loaded.records.count, 100)
        XCTAssertEqual(loaded.records.first?.scriptID, "script-0")
        XCTAssertEqual(loaded.records.last?.scriptID, "script-99")
    }
    func testPreviewPersistsForOverview() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(root: root)
        let id = UUID()
        let result = ScriptResult(protocolVersion: 1, type: .text, content: ["message": .string("概览预览")])
        try store.savePreview(result, for: id)
        XCTAssertEqual(store.loadPreview(for: id)?.content["message"], .string("概览预览"))
        store.deletePreview(for: id)
        XCTAssertNil(store.loadPreview(for: id))
    }
    func testScriptTimeoutReturnsWithoutWaitingForChild() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entry = root.appending(path: "run.sh")
        try "#!/bin/sh\nexec /bin/sleep 5\n".write(to: entry, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        let manifest = ScriptManifest(schemaVersion: 1, id: "test.timeout", name: "Timeout", version: "1", description: "", entrypoint: "run.sh", outputType: .text)
        let start = Date()
        do {
            _ = try await ScriptRunner().run(InstalledScript(manifest: manifest, directory: root.path), parameters: [:], timeout: 0.1)
            XCTFail("脚本应超时")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("超过"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
