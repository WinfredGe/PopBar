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
        guard let config = readConfig(bundleURL: bundleURL) else {
            NSLog("PopClip 扩展无法解析: \(bundleURL.lastPathComponent)")
            return []
        }
        let extName = (config["name"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let options = defaultOptionValues(config)

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

        let loaded = actionDicts
            .filter { satisfiesRequirements($0, options: options) }
            .compactMap { makeAction($0, extName: extName, bundleURL: bundleURL, options: options) }
        if loaded.isEmpty {
            NSLog("PopClip 扩展 \(extName) 没有可支持的动作(支持 url / shell / applescript)")
        }
        return loaded
    }

    /// 提取扩展 options 的默认值(defaultValue 优先,multiple 类型取 values 第一项)
    private static func defaultOptionValues(_ config: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for option in (config["options"] as? [[String: Any]]) ?? [] {
            guard let id = (option["identifier"] as? String)?.lowercased() else { continue }
            if let dv = option["defaultvalue"] {
                if let b = dv as? Bool {
                    out[id] = b ? "1" : "0"
                } else {
                    out[id] = "\(dv)"
                }
            } else if let values = option["values"] as? [Any], let first = values.first {
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
        let title = (dict["title"] as? String) ?? extName
        let icon = (dict["icon"] as? String).flatMap { name -> NSImage? in
            // PopClip 的文本图标(如 "square filled A")不含扩展名,暂不支持
            guard name.contains(".") else { return nil }
            return NSImage(contentsOf: bundleURL.appendingPathComponent(name))
        }

        if let urlTemplate = dict["url"] as? String {
            // PopClip 用 *** 作为 URL 编码后选中文本的占位符
            let template = urlTemplate
                .replacingOccurrences(of: "***", with: "{text}")
                .replacingOccurrences(of: "{popclip text}", with: "{text}")
            return URLPluginAction(title: title, icon: icon, template: template)
        }

        if let scriptFile = dict["shell script file"] as? String {
            return PopClipShellAction(title: title, icon: icon,
                                      scriptURL: bundleURL.appendingPathComponent(scriptFile),
                                      interpreter: dict["interpreter"] as? String,
                                      workingDirectory: bundleURL)
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

// MARK: - PopClip 风格 shell 动作

struct PopClipShellAction: PopAction {
    let title: String
    let icon: NSImage?
    let scriptURL: URL
    let interpreter: String?
    let workingDirectory: URL

    func perform(with text: String) {
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
        env["POPCLIP_TEXT"] = text   // PopClip 官方约定的环境变量
        env["POPBAR_TEXT"] = text
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

    func perform(with text: String) {
        // AppleScript 字符串字面量转义
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        var script = scriptTemplate.replacingOccurrences(of: "{popclip text}", with: escape(text))
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
