import Cocoa

// MARK: - 动作协议

protocol PopAction {
    /// 稳定标识,用于设置里的排序和启用/禁用持久化
    var id: String { get }
    var title: String { get }
    var icon: NSImage? { get }
    /// 工具条按钮标题(默认固定 title;Word Count 等扩展按选中文本动态生成)
    func displayTitle(for text: String) -> String
    func perform(with selection: SelectionPayload)
}

extension PopAction {
    var id: String { "action.\(title)" }
    func displayTitle(for text: String) -> String { title }
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
    let icon: NSImage? = ActionIcon.fallback(for: "复制")

    func perform(with selection: SelectionPayload) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(selection.text, forType: .string)
    }
}

// MARK: - 内置动作 2:翻译(系统自带 Translation 框架,英→中,结果显示在浮窗)

struct TranslateAction: PopAction {
    let id = "builtin.translate"
    let title = "翻译"
    let icon: NSImage? = ActionIcon.fallback(for: "翻译")

    func perform(with selection: SelectionPayload) {
        Task { @MainActor in
            TranslationPanelController.shared.translate(selection.text, near: selection.location)
        }
    }
}

// MARK: - 内置动作 3:发给 Claude 网页版

struct ClaudeWebAction: PopAction {
    let id = "builtin.claude"
    let title = "Claude"
    let icon: NSImage? = ActionIcon.fallback(for: "Claude")

    func perform(with selection: SelectionPayload) {
        // claude.ai/new?q=... 会带着文本新建一个对话
        var components = URLComponents(string: "https://claude.ai/new")!
        components.queryItems = [URLQueryItem(name: "q", value: "请翻译如下文本：\n\n" + selection.text)]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}
