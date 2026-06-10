import Cocoa

/// 扩展图标加载:PNG/JPG/SVG 统一缩放到固定尺寸;失败时用 SF Symbol 占位
enum ActionIcon {

    static let toolbarSize: CGFloat = 18

    /// 从扩展包加载图标文件
    static func load(fileName: String, bundleURL: URL) -> NSImage? {
        let url = bundleURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if fileName.lowercased().hasSuffix(".svg") {
            return loadSVG(url)
        }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return sized(image)
    }

    /// 按动作名称猜测 SF Symbol(扩展无图标文件时的占位)
    static func fallback(for title: String) -> NSImage {
        let t = title.lowercased()
        let symbol: String
        if t.contains("wikipedia") || t.contains("wiki") { symbol = "book.closed" }
        else if t.contains("scholar") { symbol = "graduationcap" }
        else if t.contains("google") { symbol = "magnifyingglass" }
        else if t.contains("bing") { symbol = "magnifyingglass.circle" }
        else if t.contains("markdown") || t.contains("md") { symbol = "doc.richtext" }
        else if t.contains("word") && t.contains("count") || t.contains("词") { symbol = "number" }
        else if t.contains("terminal") || t.contains("rtc") { symbol = "terminal" }
        else if t.contains("chatgpt") || t.contains("openai") { symbol = "bubble.left" }
        else if t.contains("claude") { symbol = "sparkles" }
        else if t.contains("translate") || t.contains("翻译") { symbol = "character.bubble" }
        else if t.contains("copy") || t.contains("复制") { symbol = "doc.on.doc" }
        else if t.contains("deepl") { symbol = "globe" }
        else { symbol = "puzzlepiece.extension" }
        return sized(NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                     ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!)
    }

    /// 工具条用:优先已有图标,否则按标题生成占位符
    static func forToolbar(action: PopAction) -> NSImage {
        if let icon = action.icon { return sized(icon) }
        return fallback(for: action.title)
    }

    static func sized(_ image: NSImage) -> NSImage {
        let side = toolbarSize
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }

    private static func loadSVG(_ url: URL) -> NSImage? {
        // macOS 可用 NSImage 直接读部分 SVG;读不到则返回 nil 走 SF Symbol
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data), image.isValid, image.size.width > 0 else {
            return nil
        }
        return sized(image)
    }
}
