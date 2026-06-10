import Cocoa

/// 处理"从官网一键安装插件":
/// 网页上放链接 popbar://install?url=https%3A%2F%2Fyoursite.com%2Fplugins%2Ffoo.zip
/// 点击 → 系统唤起 PopBar → 用户确认 → 下载 zip → 解压出 .popext → 装入扩展目录。
final class PluginInstaller {
    static let shared = PluginInstaller()

    func handle(url: URL) {
        guard url.scheme == "popbar",
              url.host == "install",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let packageString = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let packageURL = URL(string: packageString),
              packageURL.scheme == "https"           // 只允许 HTTPS 来源
        else { return }

        // 安全:始终让用户确认来源,绝不静默安装
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "安装 PopBar 插件?"
            alert.informativeText = "将从以下地址下载并安装插件:\n\(packageURL.absoluteString)\n\n只安装你信任的来源的插件——shell 类型插件可以在你的电脑上执行任意命令。"
            alert.addButton(withTitle: "安装")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.download(packageURL)
        }
    }

    private func download(_ url: URL) {
        URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            guard let tempURL, error == nil else {
                self.notify("下载失败", error?.localizedDescription ?? "未知错误")
                return
            }
            self.install(zipAt: tempURL)
        }.resume()
    }

    /// 双击 / "打开方式"安装本地扩展包:
    /// 支持 .popclipextz / .popextz / .zip 压缩包,以及 .popclipext / .popext 文件夹。
    func installLocalPackage(at fileURL: URL) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "安装扩展?"
            alert.informativeText = "将安装扩展:\n\(fileURL.lastPathComponent)\n\n只安装你信任的来源的扩展——shell 类型扩展可以在你的电脑上执行任意命令。"
            alert.addButton(withTitle: "安装")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            if Self.bundleExtensions.contains(fileURL.pathExtension) {
                self.moveToExtensions(bundle: fileURL, keepOriginal: true)
            } else {
                self.install(zipAt: fileURL)
            }
        }
    }

    private static let bundleExtensions: Set<String> = ["popext", "popclipext"]

    private func install(zipAt zipURL: URL) {
        let fm = FileManager.default
        let unpackDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: unpackDir, withIntermediateDirectories: true)

        // 用系统自带 ditto 解压(保留 bundle 结构;.popclipextz/.popextz 本质就是 zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", zipURL.path, unpackDir.path]
        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {
            notify("安装失败", "解压出错")
            return
        }

        // 递归查找包里的 .popext / .popclipext(GitHub 下载的 zip 常会多套一层目录)
        guard let bundle = findExtensionBundle(in: unpackDir) else {
            notify("安装失败", "压缩包中没有 .popext 或 .popclipext 扩展")
            return
        }
        moveToExtensions(bundle: bundle, keepOriginal: false)
    }

    private func findExtensionBundle(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator where Self.bundleExtensions.contains(url.pathExtension) {
            return url
        }
        return nil
    }

    private func moveToExtensions(bundle: URL, keepOriginal: Bool) {
        let fm = FileManager.default
        let destination = PluginManager.shared.extensionsDirectory
            .appendingPathComponent(bundle.lastPathComponent)
        try? fm.removeItem(at: destination)   // 覆盖旧版本
        do {
            if keepOriginal {
                try fm.copyItem(at: bundle, to: destination)
            } else {
                try fm.moveItem(at: bundle, to: destination)
            }
        } catch {
            notify("安装失败", error.localizedDescription)
            return
        }

        DispatchQueue.main.async {
            PluginManager.shared.loadAll()
            self.notify("扩展已安装", destination.deletingPathExtension().lastPathComponent)
        }
    }

    private func notify(_ title: String, _ body: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = body
            alert.runModal()
        }
    }
}
