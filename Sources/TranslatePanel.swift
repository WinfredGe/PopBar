import Cocoa
import SwiftUI
import Translation

/// 系统离线翻译(英→简体中文),结果显示在选区附近的浮窗里。
/// 基于 macOS 15+ 的 Translation 框架;首次使用会引导下载语言模型。
@MainActor
final class TranslationPanelController: ObservableObject {
    static let shared = TranslationPanelController()

    @Published var sourceText: String = ""
    @Published var resultText: String?
    @Published var configuration: TranslationSession.Configuration?

    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                        styleMask: [.nonactivatingPanel, .titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "翻译"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: TranslationResultView(controller: self))
        // 用关闭按钮关掉浮窗时,同步停掉鼠标位置检测计时器
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: p, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        return p
    }()

    /// 光标离开浮窗周边这个距离后自动关闭
    private let dismissMargin: CGFloat = 60
    private var proximityTimer: Timer?

    /// 直接显示一段文本(不翻译),供 JS 扩展的 popclip.showText 使用
    func showPlainText(_ text: String, near point: NSPoint) {
        sourceText = ""        // 空 source,translationTask 会跳过
        resultText = text
        present(near: point)
    }

    func translate(_ text: String, near point: NSPoint) {
        sourceText = text
        resultText = nil

        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh-Hans"))
        } else {
            // 同一语言对再次翻译:invalidate 让 translationTask 重新执行
            configuration?.invalidate()
        }
        present(near: point)
    }

    private func present(near point: NSPoint) {
        var origin = NSPoint(x: point.x - 190, y: point.y - panel.frame.height - 24)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - panel.frame.width - 4))
            origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - panel.frame.height - 4))
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        startProximityWatch()
    }

    /// 轮询鼠标位置:光标离开浮窗(含外边距)就自动关闭,无需手动点关闭按钮
    private func startProximityWatch() {
        proximityTimer?.invalidate()
        proximityTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let zone = self.panel.frame.insetBy(dx: -self.dismissMargin, dy: -self.dismissMargin)
                if !zone.contains(NSEvent.mouseLocation) {
                    self.dismiss()
                }
            }
        }
    }

    func dismiss() {
        proximityTimer?.invalidate()
        proximityTimer = nil
        panel.orderOut(nil)
    }
}

private struct TranslationResultView: View {
    @ObservedObject var controller: TranslationPanelController

    var body: some View {
        ScrollView {
            HStack {
                if let result = controller.resultText {
                    Text(result)
                        .textSelection(.enabled)
                } else {
                    ProgressView().controlSize(.small)
                    Text("翻译中…").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .translationTask(controller.configuration) { session in
            let source = controller.sourceText
            guard !source.isEmpty else { return }
            do {
                let response = try await session.translate(source)
                controller.resultText = response.targetText
            } catch {
                controller.resultText = "翻译失败：\(error.localizedDescription)\n\n如果是首次使用，请在 系统设置 → 通用 → 语言与地区 → 翻译语言 中下载\"英语\"和\"简体中文\"模型。"
            }
        }
    }
}
