import Cocoa

// MARK: - 动作协议

protocol PopAction {
    var title: String { get }
    var icon: NSImage? { get }
    func perform(with text: String)
}

enum ActionRegistry {
    /// 内置动作 + 已安装插件动作
    static func actions() -> [PopAction] {
        var list: [PopAction] = [CopyAction(), TranslateAction(), ClaudeWebAction()]
        list.append(contentsOf: PluginManager.shared.actions)
        return list
    }
}

// MARK: - 内置动作 1:复制

struct CopyAction: PopAction {
    let title = "复制"
    let icon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)

    func perform(with text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - 内置动作 2:翻译(系统自带 Translation 框架,英→中,结果显示在浮窗)

struct TranslateAction: PopAction {
    let title = "翻译"
    let icon = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: nil)

    func perform(with text: String) {
        Task { @MainActor in
            TranslationPanelController.shared.translate(text, near: NSEvent.mouseLocation)
        }
    }
}

// MARK: - 内置动作 3:发给 Claude 网页版

struct ClaudeWebAction: PopAction {
    let title = "Claude"
    let icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)

    func perform(with text: String) {
        // claude.ai/new?q=... 会带着文本新建一个对话
        var components = URLComponents(string: "https://claude.ai/new")!
        components.queryItems = [URLQueryItem(name: "q", value: "请翻译如下文本：\n\n" + text)]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}
