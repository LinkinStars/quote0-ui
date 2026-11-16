import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImageParameterEditor: View {
    @ObservedObject var model: AppModel
    let instance: ScriptInstance
    let parameter: ScriptParameter

    @State private var importing = false
    @State private var drag = CGSize.zero
    private let canvas = CGSize(width: 296, height: 152)

    private var value: [String: JSONValue] {
        model.data.instances.first(where: { $0.id == instance.id })?.parameters[parameter.key]?.object ?? [:]
    }
    private var path: String { value["path"]?.string ?? "" }
    private var mode: String { value["mode"]?.string ?? "fill" }
    private var image: NSImage? { path.isEmpty ? nil : NSImage(contentsOfFile: path) }
    private var offsetX: Double { number("offsetX") }
    private var offsetY: Double { number("offsetY") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(parameter.label).fontWeight(.medium)
                Spacer()
                Button(path.isEmpty ? "选择图片…" : "更换图片…") { importing = true }
            }
            if let image {
                preview(image)
                    .frame(width: canvas.width, height: canvas.height)
                    .overlay(Rectangle().strokeBorder(.black.opacity(0.18)))
                    .accessibilityLabel("\(parameter.label)预览，显示方式\(modeName)")
                HStack {
                    Text(value["filename"]?.string ?? URL(fileURLWithPath: path).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Text("296 × 152").monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption).frame(width: canvas.width)
                HStack {
                    Text("显示方式")
                    Picker("显示方式", selection: Binding(get: { mode }, set: { update("mode", .string($0)); resetPosition() })) {
                        Text("完整").tag("fit")
                        Text("填满").tag("fill")
                        Text("拉伸").tag("stretch")
                        Text("平铺").tag("tile")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .frame(maxWidth: 420)
                Text(mode == "stretch" ? "拉伸会改变原图比例。" : "拖动预览调整图片位置；测试脚本后可查看最终墨水屏图像。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("选择一张本地图片后即可调整显示方式", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: canvas.width, height: canvas.height)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.12)))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let source): model.importImage(source, for: instance.id, parameterKey: parameter.key)
            case .failure(let error): model.statusMessage = "选择图片失败：\(error.localizedDescription)"
            }
        }
    }

    private var modeName: String {
        switch mode { case "fit": "完整"; case "stretch": "拉伸"; case "tile": "平铺"; default: "填满" }
    }

    @ViewBuilder private func preview(_ image: NSImage) -> some View {
        let size = renderedSize(for: image)
        let travelX = abs(canvas.width - size.width) / 2
        let travelY = abs(canvas.height - size.height) / 2
        ZStack {
            Color.white
            if mode == "tile" {
                Canvas { context, _ in
                    let tile = tileSize(for: image)
                    let resolved = context.resolve(Image(nsImage: image))
                    let firstX = (offsetX * tile.width / 2).rounded() - tile.width + drag.width
                    let firstY = (offsetY * tile.height / 2).rounded() - tile.height + drag.height
                    var top = firstY
                    while top < canvas.height {
                        var left = firstX
                        while left < canvas.width {
                            context.draw(resolved, in: CGRect(x: left, y: top, width: tile.width, height: tile.height))
                            left += tile.width
                        }
                        top += tile.height
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .offset(x: offsetX * travelX + drag.width, y: offsetY * travelY + drag.height)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { if mode != "stretch" { drag = $0.translation } }
            .onEnded { value in
                defer { drag = .zero }
                guard mode != "stretch" else { return }
                let x = travelX > 0 ? max(-1, min(1, offsetX + value.translation.width / travelX)) : 0
                let y = travelY > 0 ? max(-1, min(1, offsetY + value.translation.height / travelY)) : 0
                updatePosition(x: x, y: y)
            })
    }

    private func renderedSize(for image: NSImage) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return canvas }
        if mode == "stretch" { return canvas }
        if mode == "tile" {
            let tile = tileSize(for: image)
            return CGSize(width: canvas.width + tile.width, height: canvas.height + tile.height)
        }
        let scale = mode == "fit"
            ? min(canvas.width / image.size.width, canvas.height / image.size.height)
            : max(canvas.width / image.size.width, canvas.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func tileSize(for image: NSImage) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return CGSize(width: 148, height: 76) }
        let scale = min(148 / image.size.width, 76 / image.size.height)
        return CGSize(width: max(1, (image.size.width * scale).rounded()),
                      height: max(1, (image.size.height * scale).rounded()))
    }

    private func number(_ key: String) -> Double {
        if case .number(let number) = value[key] { return number }
        return 0
    }
    private func update(_ key: String, _ newValue: JSONValue) {
        model.updateInstance(instance.id) { instance in
            var object = instance.parameters[parameter.key]?.object ?? [:]
            object[key] = newValue
            instance.parameters[parameter.key] = .object(object)
        }
    }
    private func updatePosition(x: Double, y: Double) {
        model.updateInstance(instance.id) { instance in
            var object = instance.parameters[parameter.key]?.object ?? [:]
            object["offsetX"] = .number(x)
            object["offsetY"] = .number(y)
            instance.parameters[parameter.key] = .object(object)
        }
    }
    private func resetPosition() { updatePosition(x: 0, y: 0) }
}
