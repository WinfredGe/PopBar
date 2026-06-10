import Cocoa
import SwiftUI

// MARK: - 动作显示设置(顺序 + 启用/禁用),持久化到 UserDefaults
//
// 新安装的插件动作自动追加到顺序末尾并默认启用,无需重新编译;
// 设置改动即时生效(工具条每次弹出都按最新设置取动作列表)。

final class ActionSettings: ObservableObject {
    static let shared = ActionSettings()

    private let orderKey = "PopBar.actionOrder"
    private let disabledKey = "PopBar.disabledActions"

    @Published private(set) var order: [String]
    @Published private(set) var disabled: Set<String>

    private init() {
        order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        disabled = Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
    }

    /// 同步当前已加载的动作:新动作追加到末尾,已卸载的从顺序里清理
    func register(_ actions: [PopAction]) {
        let currentIDs = actions.map(\.id)
        var newOrder = order.filter { currentIDs.contains($0) }
        for id in currentIDs where !newOrder.contains(id) {
            newOrder.append(id)
        }
        if newOrder != order {
            order = newOrder
            persist()
        }
    }

    /// 应用设置:排序 + 过滤禁用项
    func apply(to actions: [PopAction]) -> [PopAction] {
        sorted(actions).filter { !disabled.contains($0.id) }
    }

    func sorted(_ actions: [PopAction]) -> [PopAction] {
        actions.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.id) ?? order.count + a.offset
            let ib = order.firstIndex(of: b.element.id) ?? order.count + b.offset
            return ia < ib
        }.map(\.element)
    }

    func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(order, forKey: orderKey)
        UserDefaults.standard.set(Array(disabled), forKey: disabledKey)
    }
}

// MARK: - 设置窗口

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        let all = ActionRegistry.allActions()
        ActionSettings.shared.register(all)

        var titles: [String: String] = [:]
        var icons: [String: NSImage] = [:]
        for action in all {
            titles[action.id] = titles[action.id] ?? action.title
            if let icon = action.icon { icons[action.id] = icons[action.id] ?? icon }
        }

        let view = ActionSettingsView(settings: ActionSettings.shared,
                                      titles: titles, icons: icons)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "PopBar 设置"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.contentView = NSHostingView(rootView: view)   // 每次打开刷新动作列表
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ActionSettingsView: View {
    @ObservedObject var settings: ActionSettings
    let titles: [String: String]
    let icons: [String: NSImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("工具条功能").font(.headline)
                Text("拖动调整显示顺序,取消勾选隐藏该功能。改动立即生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 8)

            List {
                ForEach(settings.order, id: \.self) { id in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { settings.isEnabled(id) },
                            set: { settings.setEnabled(id, $0) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)

                        if let icon = icons[id] {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "puzzlepiece.extension")
                                .frame(width: 16, height: 16)
                                .foregroundStyle(.secondary)
                        }

                        Text(titles[id] ?? id)
                            .foregroundStyle(settings.isEnabled(id) ? .primary : .secondary)

                        Spacer()

                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .help("拖动调整顺序")
                    }
                    .padding(.vertical, 2)
                }
                .onMove { settings.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)

            VStack(alignment: .leading, spacing: 6) {
                Text("提示:安装新插件后,新功能会自动出现在列表末尾并默认启用。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack {
                    Link(destination: URL(string: "https://www.popclip.app/extensions/")!) {
                        Label("浏览 PopClip 扩展库,下载更多插件…", systemImage: "puzzlepiece.extension")
                            .font(.caption)
                    }
                    Spacer()
                    Button("打开扩展目录") {
                        NSWorkspace.shared.open(PluginManager.shared.extensionsDirectory)
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 320, minHeight: 380)
    }
}
