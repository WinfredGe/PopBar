import Cocoa

// MARK: - 插件清单格式(仿 PopClip 的 Config,简化为 JSON)
//
// MyPlugin.popext/
// ├── manifest.json
// ├── icon.png          (可选)
// └── run.sh            (type=shell 时)
//
// manifest.json 示例:
// {
//   "name": "大写",
//   "type": "url",                              // "url" 或 "shell"
//   "url": "https://example.com/?q={text}",     // {text} 会被替换为选中文本(已编码)
//   "icon": "icon.png"
// }
// {
//   "name": "转大写",
//   "type": "shell",
//   "script": "run.sh"                          // 选中文本通过环境变量 POPBAR_TEXT 传入
// }

struct PluginManifest: Codable {
    let name: String
    let type: String           // "url" | "shell"
    let url: String?
    let script: String?
    let icon: String?
}

// MARK: - 插件管理器

final class PluginManager {
    static let shared = PluginManager()

    private(set) var actions: [PopAction] = []
    /// 有扩展需要富文本 HTML 时,划词会额外走 ⌘C 读取剪贴板 HTML
    private(set) var needsHTMLCapture = false

    let extensionsDirectory: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopBar/Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func loadAll() {
        actions = []
        needsHTMLCapture = false
        let fm = FileManager.default
        extractArchives()
        guard let bundles = try? fm.contentsOfDirectory(at: extensionsDirectory,
                                                        includingPropertiesForKeys: nil) else { return }
        for bundleURL in bundles {
            switch bundleURL.pathExtension {
            case "popext":
                let manifestURL = bundleURL.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
                    NSLog("跳过无效插件: \(bundleURL.lastPathComponent)")
                    continue
                }
                if let action = makeAction(manifest: manifest, bundleURL: bundleURL) {
                    actions.append(action)
                }
            case "popclipext":
                if bundleURL.lastPathComponent.contains("copy-as-markdown") {
                    needsHTMLCapture = true
                }
                actions.append(contentsOf: PopClipExtension.load(bundleURL: bundleURL))
            default:
                break
            }
        }
        NSLog("已加载 \(actions.count) 个插件动作")
    }

    /// 用户把 .popclipextz / .popextz / .zip 直接丢进扩展目录时,自动解压成扩展包
    private func extractArchives() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: extensionsDirectory,
                                                      includingPropertiesForKeys: nil) else { return }
        for archive in files where ["popclipextz", "popextz", "zip"].contains(archive.pathExtension) {
            let unpackDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? fm.createDirectory(at: unpackDir, withIntermediateDirectories: true)

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-xk", archive.path, unpackDir.path]
            guard (try? unzip.run()) != nil else { continue }
            unzip.waitUntilExit()

            guard let enumerator = fm.enumerator(at: unpackDir,
                                                 includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]) else { continue }
            var found = false
            for case let url as URL in enumerator
            where ["popext", "popclipext"].contains(url.pathExtension) {
                let destination = extensionsDirectory.appendingPathComponent(url.lastPathComponent)
                try? fm.removeItem(at: destination)
                if (try? fm.moveItem(at: url, to: destination)) != nil {
                    found = true
                    NSLog("已解压扩展包: \(archive.lastPathComponent) → \(url.lastPathComponent)")
                }
                break
            }
            if found {
                try? fm.removeItem(at: archive)
            }
        }
    }

    private func makeAction(manifest: PluginManifest, bundleURL: URL) -> PopAction? {
        let icon = manifest.icon.flatMap {
            ActionIcon.load(fileName: $0, bundleURL: bundleURL)
        } ?? ActionIcon.fallback(for: manifest.name)
        switch manifest.type {
        case "url":
            guard let template = manifest.url else { return nil }
            return URLPluginAction(title: manifest.name, icon: icon, template: template)
        case "shell":
            guard let script = manifest.script else { return nil }
            return ShellPluginAction(title: manifest.name, icon: icon,
                                     scriptURL: bundleURL.appendingPathComponent(script))
        default:
            return nil
        }
    }
}

// MARK: - URL 模板插件

struct URLPluginAction: PopAction {
    let title: String
    let icon: NSImage?
    let template: String

    func perform(with selection: SelectionPayload) {
        let encoded = selection.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: template.replacingOccurrences(of: "{text}", with: encoded)) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Shell 脚本插件

struct ShellPluginAction: PopAction {
    let title: String
    let icon: NSImage?
    let scriptURL: URL

    func perform(with selection: SelectionPayload) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["POPBAR_TEXT"] = selection.text
        process.environment = env
        try? process.run()
    }
}
