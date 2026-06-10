import Cocoa

// MARK: - PopClip 官方扩展(.popclipext)兼容层
//
// popclip.app/extensions 下载的是 .popclipextz(zip),解压后是 XXX.popclipext 文件夹,
// 配置文件为 Config.plist(老格式,键如 "Shell Script File")或
// Config.yaml / Config.json(新格式,键为小写 "shell script file")。
//
// 支持的动作类型:url、shell script file、applescript / applescript file。
// javascript / service / key combo 等类型暂不支持,加载时跳过并记录日志。
//
// options:不提供设置界面,统一采用默认值(defaultValue 或 values 的第一项);
// requirements 里的 "option-x=y" 会按默认值筛选动作(如 Terminal 扩展按终端类型分动作)。

enum PopClipExtension {

    static func load(bundleURL: URL) -> [PopAction] {
        // Copy as Markdown 依赖 npm 模块,用原生实现替代 JS 版
        if bundleURL.lastPathComponent.contains("copy-as-markdown") {
            let icon = ActionIcon.load(fileName: ">md.png", bundleURL: bundleURL)
                ?? ActionIcon.fallback(for: "Copy as Markdown")
            return [CopyAsMarkdownAction(icon: icon)]
        }

        guard let config = readConfig(bundleURL: bundleURL) else {
            NSLog("PopClip 扩展无法解析: \(bundleURL.lastPathComponent)")
            return []
        }
        let extName = (config["name"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        var options = defaultOptionValues(config)

        // 用户可在扩展目录里放 popbar-options.json(平面 key:value)覆盖选项默认值,
        // 例如 {"site": "zh.wikipedia.org"}
        let overrideURL = bundleURL.appendingPathComponent("popbar-options.json")
        if let data = try? Data(contentsOf: overrideURL),
           let overrides = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in overrides {
                options[key.lowercased()] = "\(value)"
            }
        }

        // 单动作直接定义在顶层;多动作放在 actions 数组里
        let actionDicts: [[String: Any]]
        if let actions = config["actions"] as? [[String: Any]] {
            // 顶层的 icon 等作为每个动作的默认值
            actionDicts = actions.map { action in
                var merged = action
                if merged["icon"] == nil { merged["icon"] = config["icon"] }
                return merged
            }
        } else {
            actionDicts = [config]
        }

        var loaded = actionDicts
            .filter { satisfiesRequirements($0, options: options) }
            .compactMap { makeAction($0, extName: extName, bundleURL: bundleURL, options: options) }

        // 静态配置没产出动作时,尝试 JS/TS 模块(popclip.app 上的新扩展大多是这种)
        if loaded.isEmpty, let scriptURL = findJSModule(bundleURL: bundleURL, config: config) {
            loaded = PopClipJSEngine.loadActions(scriptURL: scriptURL, bundleURL: bundleURL,
                                                 extName: extName, options: options)
        }
        if loaded.isEmpty {
            NSLog("PopClip 扩展 \(extName) 没有可支持的动作(支持 url / shell / applescript / js / ts)")
        }
        return loaded
    }

    /// 查找 JS/TS 入口:config 的 module 字段优先,其次按惯例找 Config.js / Config.ts
    private static func findJSModule(bundleURL: URL, config: [String: Any]) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let module = config["module"] as? String { candidates.append(module) }
        candidates += ["Config.js", "Config.ts", "config.js", "config.ts"]
        for name in candidates {
            let url = bundleURL.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 提取扩展 options 的默认值(defaultValue 优先,multiple 类型取 values 第一项)。
    /// 同时兼容新格式(identifier/defaultValue/values)和
    /// 老 plist 格式(Option Identifier / Option Default Value / Option Values)。
    private static func defaultOptionValues(_ config: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for option in (config["options"] as? [[String: Any]]) ?? [] {
            let identifier = (option["identifier"] ?? option["option identifier"]) as? String
            guard let id = identifier?.lowercased() else { continue }
            let defaultValue = option["defaultvalue"]
                ?? option["default value"]
                ?? option["option default value"]
            if let dv = defaultValue {
                if let b = dv as? Bool {
                    out[id] = b ? "1" : "0"
                } else {
                    out[id] = "\(dv)"
                }
            } else if let values = (option["values"] ?? option["option values"]) as? [Any],
                      let first = values.first {
                out[id] = "\(first)"
            } else {
                out[id] = ""
            }
        }
        return out
    }

    /// 按默认 option 值筛选动作;text/copy 等文本类要求总是满足,未知要求忽略
    private static func satisfiesRequirements(_ dict: [String: Any], options: [String: String]) -> Bool {
        for requirement in (dict["requirements"] as? [String]) ?? [] {
            let r = requirement.lowercased()
            guard r.hasPrefix("option-") else { continue }
            let body = r.dropFirst("option-".count)
            let parts = body.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let expected = String(parts[1])
            if options[key]?.lowercased() != expected { return false }
        }
        return true
    }

    // MARK: 配置读取

    private static func readConfig(bundleURL: URL) -> [String: Any]? {
        let fm = FileManager.default
        var merged: [String: Any] = [:]

        // 同一个扩展可能同时有 Config.plist(常为服务器生成的存根,只含名字)
        // 和 Config.json/yaml(真正的配置),全部解析后合并,后者覆盖前者
        for name in ["Config.plist", "config.plist",
                     "Config.yaml", "Config.yml", "config.yaml", "config.yml",
                     "Config.json", "config.json"] {
            let url = bundleURL.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else { continue }
            var parsed: [String: Any]?
            switch url.pathExtension.lowercased() {
            case "plist":
                parsed = try? PropertyListSerialization
                    .propertyList(from: data, format: nil) as? [String: Any]
            case "json":
                parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            default:
                parsed = String(data: data, encoding: .utf8).map(parseSimpleYAML)
            }
            if let parsed {
                merged.merge(normalize(parsed)) { _, new in new }
            }
        }
        guard !merged.isEmpty else { return nil }

        // plist 存根用 "Extension Name" 字段,补成标准的 name
        if merged["name"] == nil, let extensionName = merged["extension name"] {
            merged["name"] = extensionName
        }
        return merged
    }

    /// plist 老格式键是 "Shell Script File" 风格,统一转小写以兼容两种写法
    private static func normalize(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in dict {
            let k = key.lowercased()
            if let nested = value as? [Any] {
                // 数组里的字典递归归一化,字符串等标量原样保留(如 requirements、values)
                out[k] = nested.map { ($0 as? [String: Any]).map(normalize) ?? $0 }
            } else {
                out[k] = value
            }
        }
        return out
    }

    // MARK: 动作构造

    private static func makeAction(_ dict: [String: Any], extName: String,
                                   bundleURL: URL, options: [String: String]) -> PopAction? {
        let title = resolveLocalizedString(dict["title"]) ?? extName
        let iconName = (dict["icon"] ?? dict["image file"]) as? String   // 老 plist 格式用 Image File
        let icon: NSImage? = iconName.flatMap { name -> NSImage? in
            guard name.contains(".") else { return nil }
            return ActionIcon.load(fileName: name, bundleURL: bundleURL)
        } ?? ActionIcon.fallback(for: title)

        // Word Count:标题含 {popclip wordcount},按钮上动态显示字数
        if title.localizedCaseInsensitiveContains("{popclip wordcount}") {
            return WordCountAction(titleTemplate: title, icon: icon)
        }

        if let urlTemplate = dict["url"] as? String {
            // PopClip 用 *** 作为 URL 编码后选中文本的占位符;
            // {popclip option x} 占位符按选项默认值在加载时替换(如 Wikipedia 的站点域名)
            var template = urlTemplate
                .replacingOccurrences(of: "***", with: "{text}")
                .replacingOccurrences(of: "{popclip text}", with: "{text}")
            for (key, value) in options {
                template = template.replacingOccurrences(of: "{popclip option \(key)}",
                                                         with: value,
                                                         options: .caseInsensitive)
            }
            return URLPluginAction(title: title, icon: icon, template: template)
        }

        if let scriptFile = dict["shell script file"] as? String {
            return PopClipShellAction(title: title, icon: icon,
                                      scriptURL: bundleURL.appendingPathComponent(scriptFile),
                                      interpreter: dict["interpreter"] as? String,
                                      workingDirectory: bundleURL,
                                      options: options)
        }

        if let scriptFile = dict["applescript file"] as? String,
           let template = try? String(contentsOf: bundleURL.appendingPathComponent(scriptFile),
                                      encoding: .utf8) {
            return PopClipAppleScriptAction(title: title, icon: icon,
                                            scriptTemplate: template, options: options)
        }
        if let inline = dict["applescript"] as? String {
            return PopClipAppleScriptAction(title: title, icon: icon,
                                            scriptTemplate: inline, options: options)
        }
        return nil
    }

    /// 解析 PopClip 多语言标题(字符串或 {"en": "...", "fr": "..."})
    private static func resolveLocalizedString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let dict = value as? [String: Any] {
            let locale = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
            if let match = dict.first(where: { $0.key.lowercased().hasPrefix(locale) })?.value as? String {
                return match
            }
            return dict["en"] as? String ?? dict.values.compactMap { $0 as? String }.first
        }
        return nil
    }

    // MARK: 极简 YAML 解析
    //
    // 只支持顶层 `key: value` 标量——经典的 url / shell 型扩展配置都是平面结构。
    // 含嵌套 actions 数组的 YAML 配置请改用 Config.plist / Config.json。

    private static func parseSimpleYAML(_ text: String) -> [String: Any] {
        var dict: [String: Any] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            guard !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t") else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty, !value.isEmpty else { continue }
            dict[key] = value
        }
        return dict
    }
}

// MARK: - Word Count(动态标题)

struct WordCountAction: PopAction {
    let titleTemplate: String
    let icon: NSImage?
    let id = "popclip.wordcount"
    var title: String { "Word Count" }

    func displayTitle(for text: String) -> String {
        let count = Self.countWords(in: text)
        // 简短显示,避免按钮过宽
        return "\(count) 词"
    }

    func perform(with selection: SelectionPayload) {
        let count = Self.countWords(in: selection.text)
        Task { @MainActor in
            TranslationPanelController.shared.showPlainText("\(count) 个单词", near: selection.location)
        }
    }

    private static func countWords(in text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split { $0.isWhitespace || $0.isNewline }.count
    }
}

// MARK: - Copy as Markdown(原生实现,替代依赖 npm 的 JS 版)

struct CopyAsMarkdownAction: PopAction {
    let icon: NSImage?
    let id = "popclip.copy-as-markdown"
    let title = "Copy as Markdown"

    func perform(with selection: SelectionPayload) {
        let markdown: String
        if let html = selection.html, !html.isEmpty {
            markdown = HTMLToMarkdown.convert(html)
        } else {
            markdown = selection.text
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdown, forType: .string)
    }
}

// MARK: - PopClip 风格 shell 动作

struct PopClipShellAction: PopAction {
    let title: String
    let icon: NSImage?
    let scriptURL: URL
    let interpreter: String?
    let workingDirectory: URL
    var options: [String: String] = [:]

    func perform(with selection: SelectionPayload) {
        let process = Process()
        if let interpreter, !interpreter.isEmpty {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [interpreter, scriptURL.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
        }
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        env["POPCLIP_TEXT"] = selection.text
        env["POPBAR_TEXT"] = selection.text
        for (key, value) in options {
            env["POPCLIP_OPTION_\(key.uppercased())"] = value   // PopClip 官方约定
        }
        process.environment = env
        try? process.run()
    }
}

// MARK: - PopClip 风格 AppleScript 动作
//
// PopClip 在脚本里做字面量替换:{popclip text}、{popclip option <id>}。
// 首次对目标 App(如 Terminal)发送 AppleEvent 时,系统会弹"自动化"授权,允许即可。

struct PopClipAppleScriptAction: PopAction {
    let title: String
    let icon: NSImage?
    let scriptTemplate: String
    let options: [String: String]

    func perform(with selection: SelectionPayload) {
        // AppleScript 字符串字面量转义
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        var script = scriptTemplate.replacingOccurrences(of: "{popclip text}", with: escape(selection.text))
        for (key, value) in options {
            script = script.replacingOccurrences(of: "{popclip option \(key)}",
                                                 with: escape(value))
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("popbar-\(UUID().uuidString).applescript")
        do {
            try script.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            NSLog("AppleScript 动作写临时文件失败: \(error.localizedDescription)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [tmp.path]
        process.terminationHandler = { _ in try? FileManager.default.removeItem(at: tmp) }
        try? process.run()
    }
}
