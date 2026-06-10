import Cocoa
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let monitor = SelectionMonitor()
    private let popup = PopupPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureAccessibilityPermission()
        setupStatusItem()
        PluginManager.shared.loadAll()

        monitor.onSelection = { [weak self] selection in
            guard let self else { return }
            let actions = ActionRegistry.actions()
            self.popup.show(selection: selection, actions: actions)
        }
        monitor.start()
    }

    // MARK: - 辅助功能权限

    private var trustPollTimer: Timer?

    private func ensureAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else { return }

        // 系统会自动弹出"打开辅助功能设置"的引导;
        // 轮询授权状态,授权后自动生效,无需手动重启 App
        NSLog("等待用户授予辅助功能权限…")
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.trustPollTimer = nil
            NSLog("辅助功能权限已授予,划词功能生效")
        }
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.cursor",
                                           accessibilityDescription: "PopBar")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开扩展目录", action: #selector(openExtensionsFolder), keyEquivalent: "")
        menu.addItem(withTitle: "重新加载扩展", action: #selector(reloadPlugins), keyEquivalent: "r")
        menu.addItem(.separator())
        launchAtLoginItem = menu.addItem(withTitle: "开机自启动",
                                         action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 PopBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    // MARK: - 开机自启动 (SMAppService, macOS 13+)

    private var launchAtLoginItem: NSMenuItem!

    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("切换开机自启动失败: \(error.localizedDescription)")
        }
    }

    @objc private func openSettings() {
        Task { @MainActor in
            SettingsWindowController.shared.show()
        }
    }

    @objc private func openExtensionsFolder() {
        NSWorkspace.shared.open(PluginManager.shared.extensionsDirectory)
    }

    @objc private func reloadPlugins() {
        PluginManager.shared.loadAll()
    }

    // MARK: - 扩展安装入口
    //
    // 1. popbar://install?url=...(官网一键安装,配合 Info.plist 的 CFBundleURLTypes)
    // 2. 双击 / "打开方式"打开 .popclipextz / .popextz / .popclipext / .popext
    //    (配合 Info.plist 的 CFBundleDocumentTypes)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                PluginInstaller.shared.installLocalPackage(at: url)
            } else {
                PluginInstaller.shared.handle(url: url)
            }
        }
    }
}
