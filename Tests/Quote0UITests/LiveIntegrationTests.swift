import XCTest
@testable import Quote0UI

final class LiveIntegrationTests: XCTestCase {
    private func config() throws -> [String: String] {
        guard let path = ProcessInfo.processInfo.environment["QUOTE0_ENV_FILE"] else {
            throw XCTSkip("需设置 QUOTE0_ENV_FILE 指向本机密钥文件")
        }
        let file = URL(fileURLWithPath: path)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        var result: [String: String] = [:]
        for line in lines where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return result
    }

    @MainActor
    func testLiveKimiAndThreeSlots() async throws {
        guard ProcessInfo.processInfo.environment["QUOTE0_LIVE_TEST"] == "1" else { throw XCTSkip("需显式设置 QUOTE0_LIVE_TEST=1") }
        let config = try config()
        let apiKey = try XCTUnwrap(config["QUOTE_API_KEY"])
        let deviceID = try XCTUnwrap(config["QUOTE_DEVICE_ID"])
        let kimiKey = try XCTUnwrap(config["KIMI_API_KEY"])
        let api = DotAPIClient(apiKey: apiKey)
        let devices = try await api.devices()
        XCTAssertTrue(devices.contains { $0.id == deviceID && $0.model == "quote_0" })
        let slots = try await api.slots(deviceID: deviceID)
        XCTAssertTrue([OutputType.text, .image, .canvas].allSatisfy { type in slots.contains { $0.type == type.slotType && $0.key != nil } })

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scriptsRoot = ProcessInfo.processInfo.environment["QUOTE0_SCRIPTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appending(path: "ScriptCatalog")
        let directory = scriptsRoot.appending(path: "scripts/kimi-usage")
        let manifest = try JSONDecoder().decode(ScriptManifest.self, from: Data(contentsOf: directory.appending(path: "script.json")))
        let installed = InstalledScript(manifest: manifest, directory: directory.path)
        let kimi = try await ScriptRunner().run(installed, parameters: ["kimiApiKey": .string(kimiKey), "showResetTime": .bool(true)])
        XCTAssertEqual(kimi.type, .image)
        XCTAssertTrue((kimi.content["image"]?.string ?? "").hasPrefix("data:image/png;base64,"))

        guard ProcessInfo.processInfo.environment["QUOTE0_LIVE_WRITE"] == "1" else { return }
        let textDirectory = root.appending(path: "Sources/Quote0UI/Resources/BundledScripts/demo-text")
        let textManifest = try JSONDecoder().decode(ScriptManifest.self, from: Data(contentsOf: textDirectory.appending(path: "script.json")))
        let textResult = try await ScriptRunner().run(InstalledScript(manifest: textManifest, directory: textDirectory.path), parameters: ["message": .string("quote0UI 文本测试")])
        let textSlot = try XCTUnwrap(slots.first { $0.type == "TEXT_API" }?.key)
        try await api.send(result: textResult, directory: textDirectory, deviceID: deviceID, taskKey: textSlot, refreshNow: false)

        let imageSlot = try XCTUnwrap(slots.first { $0.type == "IMAGE_API" }?.key)
        let imageDirectory = root.appending(path: "Sources/Quote0UI/Resources/BundledScripts/demo-image")
        let imageScript = try JSONDecoder().decode(ScriptManifest.self, from: Data(contentsOf: imageDirectory.appending(path: "script.json")))
        let sampleImage = root.appending(path: "Tests/Quote0UITests/Fixtures/sample.png")
        let imageResult = try await ScriptRunner().run(InstalledScript(manifest: imageScript, directory: imageDirectory.path), parameters: [
            "picture": .object(["path": .string(sampleImage.path), "mode": .string("fill"), "offsetX": .number(0), "offsetY": .number(0)])
        ])
        try await api.send(result: imageResult, directory: imageDirectory, deviceID: deviceID, taskKey: imageSlot, refreshNow: false)
        try await api.send(result: kimi, directory: directory, deviceID: deviceID, taskKey: imageSlot, refreshNow: false)

        let canvasDirectory = root.appending(path: "Sources/Quote0UI/Resources/BundledScripts/demo-canvas")
        let canvasScript = try JSONDecoder().decode(ScriptManifest.self, from: Data(contentsOf: canvasDirectory.appending(path: "script.json")))
        let canvasResult = try await ScriptRunner().run(InstalledScript(manifest: canvasScript, directory: canvasDirectory.path), parameters: [:])
        let canvasSlot = try XCTUnwrap(slots.first { $0.type == "CANVAS_API" }?.key)
        try await api.send(result: canvasResult, directory: canvasDirectory, deviceID: deviceID, taskKey: canvasSlot, refreshNow: false)
    }

}
