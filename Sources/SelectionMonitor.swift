import Cocoa
import ApplicationServices

/// 划词检测:全局监听鼠标,判断"刚刚发生了一次文本选择",
/// 然后优先用 Accessibility API 取词,失败时模拟 ⌘C 兜底。
final class SelectionMonitor {

    var onSelection: ((SelectionPayload) -> Void)?

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
            let dx = upLocation.x - self.mouseDownLocation.x
            let dy = upLocation.y - self.mouseDownLocation.y
            let dragDistance = hypot(dx, dy)
            let isDoubleClick = event.clickCount >= 2
            let isDragSelect = dragDistance > 4 // 拖动超过 4pt 视为可能的拖选

            guard isDoubleClick || isDragSelect else { return }
            guard !self.shouldSkipCapture(dx: dx, dy: dy, dragDistance: dragDistance) else { return }

            // 拖选距离越长,目标 App 更新选区越慢,适当多等一会
            let delay = min(0.12 + dragDistance / 2000, 0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
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

    /// 完全不触发划词(含 AX):截图/框选类 App 及大面积拖选
    private let captureSkipBundleIDs: Set<String> = [
        "com.apple.screencaptureui",   // 系统截图
        "com.apple.ScreenCaptureAgent",
        "com.getcleanshot.app",        // CleanShot X
        "com.getcleanshot.CleanShot-X",
        "com.chungkengshottr.Shottr",  // Shottr
        "com.snipaste.app",            // Snipaste
        "com.biji.Snipaste",
        "com.boyce.xnip",              // Xnip
        "com.tencent.xinWeChat",       // 微信截图浮层时
        "com.tencent.qq",              // QQ 截图
        "com.apple.Preview",           // 预览里框选标注
    ]

    /// 前台 App 黑名单:这些 App 里 ⌘C 有副作用,不走剪贴板兜底;AX 取词仍保留
    private let clipboardFallbackBlacklist: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.Photos",
        "com.apple.iphonesimulator",
    ]

    /// 仅在前台是截图/框选类 App 时跳过(不按拖动距离判断,避免误杀多行划选)
    private func shouldSkipCapture(dx: CGFloat, dy: CGFloat, dragDistance: CGFloat) -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        if captureSkipBundleIDs.contains(bundleID) { return true }
        let lower = bundleID.lowercased()
        if lower.contains("screenshot") || lower.contains("snip")
            || lower.contains("cleanshot") || lower.contains("ishot")
            || lower.contains("shottr") || lower.contains("xnip") {
            return true
        }
        // 极端大面积框选(整屏截图手势):双向都超过 250pt 且总距离 > 500pt
        if dragDistance > 500 && abs(dx) > 250 && abs(dy) > 250 { return true }
        return false
    }

    private func captureSelection(allowClipboardFallback: Bool, at point: NSPoint) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let canUseClipboard = allowClipboardFallback
            && !clipboardFallbackBlacklist.contains(frontmost ?? "")

        if let text = selectedTextViaAX(), isUsable(text) {
            var html: String?
            // Copy as Markdown 等扩展需要 HTML:AX 只有纯文本时再走一次 ⌘C 取富文本
            if canUseClipboard, PluginManager.shared.needsHTMLCapture {
                html = selectedHTMLViaCmdC()
            }
            onSelection?(SelectionPayload(text: text, html: html, location: point))
            return
        }
        if canUseClipboard,
           let captured = selectedViaCmdC(),
           let text = captured.text,
           isUsable(text) {
            onSelection?(SelectionPayload(text: text, html: captured.html, location: point))
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

    private struct ClipboardCapture {
        let text: String?
        let html: String?
    }

    private func selectedViaCmdC() -> ClipboardCapture? {
        guard let pb = simulateCopyToPasteboard() else { return nil }
        return ClipboardCapture(text: pb.string(forType: .string),
                                html: htmlString(from: pb))
    }

    /// 仅取 HTML(不取纯文本),用于 AX 已有文本但需要富文本的场景
    private func selectedHTMLViaCmdC() -> String? {
        guard let pb = simulateCopyToPasteboard() else { return nil }
        return htmlString(from: pb)
    }

    private func simulateCopyToPasteboard() -> NSPasteboard? {
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

        let deadline = Date().addingTimeInterval(0.3)
        while pasteboard.changeCount == oldChangeCount && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard pasteboard.changeCount != oldChangeCount else { return nil }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        return pasteboard
    }

    private func htmlString(from pasteboard: NSPasteboard) -> String? {
        for type in [NSPasteboard.PasteboardType.html, .init("public.html")] {
            if let html = pasteboard.string(forType: type), !html.isEmpty { return html }
        }
        return nil
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
