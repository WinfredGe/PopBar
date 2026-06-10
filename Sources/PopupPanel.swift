import Cocoa

/// 浮动工具条:不抢焦点的 NSPanel,点击外部 / 滚动 / 超时自动消失。
final class PopupPanelController {

    private let panel: NSPanel
    private var dismissMonitors: [Any] = []
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 40),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu                     // 盖在几乎所有窗口之上
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(text: String, near point: NSPoint, actions: [PopAction]) {
        hide()

        let bar = BarView(actions: actions, text: text) { [weak self] in self?.hide() }
        panel.contentView = bar
        let size = bar.fittingSize
        panel.setContentSize(size)

        // 出现在选区上方居中,并夹在屏幕内
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y + 16)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            origin.x = max(screen.visibleFrame.minX + 4,
                           min(origin.x, screen.visibleFrame.maxX - size.width - 4))
            origin.y = min(origin.y, screen.visibleFrame.maxY - size.height - 4)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()                 // 关键:显示但不激活自己

        installDismissBehavior()
    }

    func hide() {
        panel.orderOut(nil)
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func installDismissBehavior() {
        // 点击别处 / 滚动 / 切 App → 收起
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel],
            handler: { [weak self] _ in self?.hide() }) {
            dismissMonitors.append(global)
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }
}

// MARK: - 工具条视图

private final class BarView: NSView {

    init(actions: [PopAction], text: String, dismiss: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 9
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)

        for action in actions {
            let button = FirstMouseButton(title: action.title, target: nil, action: nil)
            button.bezelStyle = .accessoryBarAction
            button.font = .systemFont(ofSize: 12, weight: .medium)
            if let icon = action.icon {
                button.image = icon
                button.imagePosition = .imageLeading
            }
            button.onClick = {
                dismiss()
                action.perform(with: text)
            }
            stack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 窗口未激活时第一下点击就能触发的按钮(浮条体验的关键细节)
private final class FirstMouseButton: NSButton {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(didClick)
        isBordered = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func didClick() { onClick?() }
}
