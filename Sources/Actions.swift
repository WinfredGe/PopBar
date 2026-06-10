import Cocoa

// MARK: - 动作协议

protocol PopAction {
    /// 稳定标识,用于设置里的排序和启用/禁用持久化
    var id: String { get }
    var title: String { get }
    var icon: NSImage? { get }
    func perform(with text: String)
}

extension PopAction {
    var id: String { "action.\(title)" }
}

enum ActionRegistry {
    /// 全量动作(内置 + 插件),不受设置过滤,供设置界面展示
    static func allActions() -> [PopAction] {
        var list: [PopAction] = [CopyAction(), TranslateAction(), ClaudeWebAction()]
        list.append(contentsOf: PluginManager.shared.actions)
        return list
    }

    /// 工具条实际显示的动作:按用户设置排序并过滤掉已禁用的
    static func actions() -> [PopAction] {
        let all = allActions()
        ActionSettings.shared.register(all)   // 新动作自动追加到顺序末尾
        return ActionSettings.shared.apply(to: all)
    }
}

// MARK: - 内置动作 1:复制

struct CopyAction: PopAction {
    let id = "builtin.copy"
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
    let id = "builtin.translate"
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
    let id = "builtin.claude"
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
