import Cocoa
import ApplicationServices

/// 划词检测:全局监听鼠标,判断"刚刚发生了一次文本选择",
/// 然后优先用 Accessibility API 取词,失败时模拟 ⌘C 兜底。
final class SelectionMonitor {

    var onSelection: ((String, NSPoint) -> Void)?

    private var upMonitor: Any?
    private var downMonitor: Any?
    private var mouseDownLocation: NSPoint = .zero

    func start() {
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.mouseDownLocation = NSEvent.mouseLocation
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self else { return }
            let upLocation = NSEvent.mouseLocation
            let dragDistance = hypot(upLocation.x - self.mouseDownLocation.x,
                                     upLocation.y - self.mouseDownLocation.y)
            let isDoubleClick = event.clickCount >= 2
            let isDragSelect = dragDistance > 4 // 拖动超过 4pt 视为可能的拖选

            guard isDoubleClick || isDragSelect else { return }

            // 稍等一下,让目标 App 完成自身的选区更新
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.captureSelection(allowClipboardFallback: true, at: upLocation)
            }
        }
    }

    func stop() {
        [upMonitor, downMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        upMonitor = nil; downMonitor = nil
    }

    /// 超过该长度大概率是误触发的全选,不弹条(URL 类动作也无法承载)
    private let maxSelectionLength = 10_000

    /// 前台 App 黑名单:这些 App 里 ⌘C 有副作用(如 Finder 是复制文件而非文本),
    /// 不走剪贴板兜底;AX 取词无副作用,仍然保留
    private let clipboardFallbackBlacklist: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.Photos",       // ⌘C 复制的是图片对象
        "com.apple.iphonesimulator",
    ]

    private func captureSelection(allowClipboardFallback: Bool, at point: NSPoint) {
        if let text = selectedTextViaAX(), isUsable(text) {
            onSelection?(text, point)
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if allowClipboardFallback,
           !clipboardFallbackBlacklist.contains(frontmost ?? ""),
           let text = selectedTextViaCmdC(), isUsable(text) {
            onSelection?(text, point)
        }
    }

    private func isUsable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= maxSelectionLength
    }

    // MARK: - 路径 1:Accessibility API(无副作用,首选)

    private func selectedTextViaAX() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement

        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused,
                                         kAXSelectedTextAttribute as CFString,
                                         &selectedRef) == .success,
           let text = selectedRef as? String, !text.isEmpty {
            return text
        }

        // 一些 App(如部分浏览器)把选区放在 focused 元素的 web area 子元素里,
        // 这里可按需递归查找 kAXSelectedTextAttribute,为简洁省略。
        return nil
    }

    // MARK: - 路径 2:模拟 ⌘C 兜底(会动剪贴板,用完恢复)

    private func selectedTextViaCmdC() -> String? {
        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboard(pasteboard)
        let oldChangeCount = pasteboard.changeCount

        // kVK_ANSI_C = 8
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return nil }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        // 等待剪贴板变化(最多 300ms)
        let deadline = Date().addingTimeInterval(0.3)
        while pasteboard.changeCount == oldChangeCount && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard pasteboard.changeCount != oldChangeCount else { return nil }

        let text = pasteboard.string(forType: .string)

        // 恢复用户原来的剪贴板内容(PopClip 同款礼貌行为)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        return text
    }

    private func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}
