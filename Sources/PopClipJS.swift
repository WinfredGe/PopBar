import Cocoa
import JavaScriptCore
import CryptoKit

// MARK: - PopClip JavaScript / TypeScript 扩展引擎
//
// popclip.app 上的新扩展大多是 JS/TS 型:Config.js / Config.ts 里调用
// defineExtension({ actions: [{ title, icon, code: (input) => {...} }] })。
//
// 本引擎用系统内置的 JavaScriptCore 执行脚本,并实现 PopClip JS API 的常用子集:
//   popclip.input.text / pasteText / copyText / openUrl / showText
//   util.getRandomValues / util.localize、print、defineExtension、module.exports
//
// TypeScript 支持:首次遇到 .ts 扩展时自动从 jsDelivr 下载官方 TypeScript
// 编译器(约 8MB,仅一次),转译结果按内容哈希缓存,之后加载零开销。

enum PopClipJSEngine {

    // MARK: 入口

    static func loadActions(scriptURL: URL, bundleURL: URL, extName: String,
                            options: [String: String]) -> [PopAction] {
        guard var source = try? String(contentsOf: scriptURL, encoding: .utf8) else { return [] }

        // .ts 一律转译;.js 若用 ES Module 语法(export/import)也走转译转成 CommonJS
        let isTS = scriptURL.pathExtension.lowercased() == "ts"
        let usesESM = source.range(of: #"^\s*(export|import)\s"#,
                                   options: .regularExpression) != nil
        if isTS || usesESM {
            guard let js = transpileTypeScript(source) else {
                // 编译器还没就绪(正在下载),下载完成后会自动重载扩展
                return []
            }
            source = js
        }

        guard let context = JSContext() else { return [] }
        context.name = "PopBar-\(extName)"
        context.exceptionHandler = { _, exception in
            NSLog("JS 异常[\(extName)]: \(exception?.toString() ?? "未知")")
        }
        installAPI(in: context, extName: extName, options: options)

        context.evaluateScript(source)

        // defineExtension 优先,其次 module.exports
        var definition = context.objectForKeyedSubscript("__popbar_definition")
        if definition == nil || definition!.isUndefined || definition!.isNull {
            definition = context.objectForKeyedSubscript("module")?
                .objectForKeyedSubscript("exports")
        }
        guard let definition, definition.isObject else {
            NSLog("PopClip JS 扩展 \(extName) 没有通过 defineExtension/module.exports 导出定义")
            return []
        }

        // 模块导出的 options 数组写入 popclip.options 默认值
        context.objectForKeyedSubscript("__popbar_applyOptionDefaults")?
            .call(withArguments: [definition])

        // actions 数组,或单个 action,或定义本身就是动作
        var actionValues: [JSValue] = []
        if let actions = definition.objectForKeyedSubscript("actions"), actions.isArray {
            let count = Int(actions.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            for i in 0..<count {
                if let v = actions.objectAtIndexedSubscript(i) { actionValues.append(v) }
            }
        } else if let single = definition.objectForKeyedSubscript("action"),
                  single.isObject || isFunction(single) {
            actionValues.append(single)
        } else if definition.objectForKeyedSubscript("code") != nil,
                  isFunction(definition.objectForKeyedSubscript("code")) {
            actionValues.append(definition)
        }

        return actionValues.compactMap { value in
            let fn: JSValue?
            if isFunction(value) {
                fn = value
            } else {
                fn = value.objectForKeyedSubscript("code")
            }
            guard let fn, isFunction(fn) else { return nil }

            let title = value.objectForKeyedSubscript("title").flatMap {
                $0.isString ? $0.toString() : nil
            } ?? extName
            let iconSpec = value.objectForKeyedSubscript("icon").flatMap {
                $0.isString ? $0.toString() : nil
            }
            let icon = makeIcon(iconSpec, title: title, bundleURL: bundleURL)
            return PopClipJSAction(title: title, icon: icon, context: context, function: fn)
        }
    }

    private static func isFunction(_ value: JSValue?) -> Bool {
        guard let value else { return false }
        return value.isObject && JSObjectIsFunction(value.context.jsGlobalContextRef, value.jsValueRef)
    }

    /// symbol:xxx → SF Symbol;*.png/*.svg → 从扩展包加载
    private static func makeIcon(_ spec: String?, title: String, bundleURL: URL) -> NSImage {
        if let spec, spec.hasPrefix("symbol:") {
            let name = String(spec.dropFirst("symbol:".count))
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return ActionIcon.sized(img)
            }
        }
        if let spec, spec.contains(".") {
            if let img = ActionIcon.load(fileName: spec, bundleURL: bundleURL) { return img }
        }
        return ActionIcon.fallback(for: title)
    }

    // MARK: PopClip API 子集

    private static func installAPI(in context: JSContext,
                                   extName: String, options: [String: String]) {
        let log: @convention(block) (JSValue) -> Void = { value in
            NSLog("[\(extName)] \(value.toString() ?? "")")
        }
        let paste: @convention(block) (String) -> Void = { pasteText($0) }
        let copy: @convention(block) (String) -> Void = { text in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        let openUrl: @convention(block) (String) -> Void = { urlString in
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        }
        let showText: @convention(block) (String) -> Void = { text in
            DispatchQueue.main.async {
                TranslationPanelController.shared.showPlainText(text, near: NSEvent.mouseLocation)
            }
        }
        context.setObject(log, forKeyedSubscript: "print" as NSString)
        context.setObject(paste, forKeyedSubscript: "__popbar_paste" as NSString)
        context.setObject(copy, forKeyedSubscript: "__popbar_copy" as NSString)
        context.setObject(openUrl, forKeyedSubscript: "__popbar_openUrl" as NSString)
        context.setObject(showText, forKeyedSubscript: "__popbar_showText" as NSString)
        context.setObject(options, forKeyedSubscript: "__popbar_options" as NSString)

        context.evaluateScript("""
        var __popbar_definition = null;
        function defineExtension(d) { __popbar_definition = d; }
        var module = { exports: {} };
        var exports = module.exports;
        // 模块导出的 options 数组 → 写入 popclip.options 默认值(保留原始类型)
        function __popbar_applyOptionDefaults(def) {
          if (!def || !Array.isArray(def.options)) { return; }
          for (var i = 0; i < def.options.length; i++) {
            var opt = def.options[i];
            if (!opt || !opt.identifier) { continue; }
            if (popclip.options[opt.identifier] !== undefined) { continue; }
            if (opt.defaultValue !== undefined) {
              popclip.options[opt.identifier] = opt.defaultValue;
            } else if (Array.isArray(opt.values) && opt.values.length > 0) {
              popclip.options[opt.identifier] = opt.values[0];
            } else if (opt.type === "boolean") {
              popclip.options[opt.identifier] = false;
            } else {
              popclip.options[opt.identifier] = "";
            }
          }
        }
        // JSC 没有 URL / URLSearchParams(WebKit API),给个够用的最小实现
        if (typeof URLSearchParams === "undefined") {
          globalThis.URLSearchParams = class {
            constructor() { this._pairs = []; }
            append(k, v) { this._pairs.push([String(k), String(v)]); }
            set(k, v) {
              this._pairs = this._pairs.filter(function (p) { return p[0] !== String(k); });
              this.append(k, v);
            }
            get(k) {
              var hit = this._pairs.find(function (p) { return p[0] === String(k); });
              return hit ? hit[1] : null;
            }
            toString() {
              return this._pairs.map(function (p) {
                return encodeURIComponent(p[0]) + "=" + encodeURIComponent(p[1]);
              }).join("&");
            }
          };
        }
        if (typeof URL === "undefined") {
          globalThis.URL = class {
            constructor(href) {
              this._base = String(href);
              this.searchParams = new URLSearchParams();
            }
            get href() {
              var q = this.searchParams.toString();
              if (!q) { return this._base; }
              return this._base + (this._base.indexOf("?") >= 0 ? "&" : "?") + q;
            }
            toString() { return this.href; }
          };
        }
        var popclip = {
          input: { text: "", html: "", markdown: "", matchedText: "", data: {} },
          context: { hasFormatting: false, canPaste: true, canCopy: true, canCut: false },
          options: __popbar_options,
          modifiers: { shift: false, option: false, command: false, control: false },
          pasteText: function (t) { __popbar_paste(String(t)); },
          copyText: function (t) { __popbar_copy(String(t)); },
          openUrl: function (u) { __popbar_openUrl(String(u)); },
          showText: function (t) { __popbar_showText(String(t)); },
          showSuccess: function () {},
          showFailure: function () {},
          performCommand: function () {},
        };
        var util = {
          localize: function (s) { return s; },
          getRandomValues: function (arr) {
            for (var i = 0; i < arr.length; i++) {
              arr[i] = Math.floor(Math.random() * 0x100000000);
            }
            return arr;
          },
          sleep: function () {},
        };
        """)
    }

    /// 把文本粘贴到前台 App(PopClip 的 pasteText 语义):
    /// 写剪贴板 → 模拟 ⌘V → 恢复原剪贴板
    private static func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)

        // kVK_ANSI_V = 9
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            pb.writeObjects(saved)
        }
    }

    // MARK: TypeScript 转译

    private static let compilerRemoteURL =
        URL(string: "https://cdn.jsdelivr.net/npm/typescript@5.5.4/lib/typescript.js")!

    private static var compilerLocalURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopBar/typescript.js")
    }

    private static var transpileCacheDirectory: URL {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopBar/transpiled", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var compilerDownloadInFlight = false

    private static func transpileTypeScript(_ source: String) -> String? {
        // 盐随转译配置变更而变,避免命中旧配置的缓存
        let digest = SHA256.hash(data: Data(("v2|" + source).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let cached = transpileCacheDirectory.appendingPathComponent("\(digest).js")
        if let js = try? String(contentsOf: cached, encoding: .utf8) {
            return js
        }

        guard let compilerSource = try? String(contentsOf: compilerLocalURL, encoding: .utf8) else {
            downloadCompiler()
            return nil
        }

        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { _, exception in
            NSLog("TypeScript 编译器异常: \(exception?.toString() ?? "未知")")
        }
        // typescript.js 可能挂全局 ts,也可能走 CommonJS,两种都兼容
        context.evaluateScript("var module = { exports: {} };")
        context.evaluateScript(compilerSource)
        context.setObject(source, forKeyedSubscript: "__popbar_src" as NSString)
        let output = context.evaluateScript("""
        (function () {
          var compiler = (typeof ts !== "undefined") ? ts : module.exports;
          return compiler.transpileModule(__popbar_src, {
            compilerOptions: {
              target: compiler.ScriptTarget.ES2022,
              module: compiler.ModuleKind.CommonJS
            }
          }).outputText;
        })()
        """)
        guard let js = output?.toString(), !js.isEmpty, js != "undefined" else {
            NSLog("TypeScript 转译失败")
            return nil
        }
        try? js.write(to: cached, atomically: true, encoding: .utf8)
        return js
    }

    private static func downloadCompiler() {
        guard !compilerDownloadInFlight else { return }
        compilerDownloadInFlight = true
        NSLog("首次加载 TypeScript 扩展,正在下载编译器(约 8MB,仅一次)…")
        URLSession.shared.downloadTask(with: compilerRemoteURL) { tempURL, _, error in
            defer { compilerDownloadInFlight = false }
            guard let tempURL, error == nil else {
                NSLog("TypeScript 编译器下载失败: \(error?.localizedDescription ?? "未知错误")")
                return
            }
            let fm = FileManager.default
            try? fm.createDirectory(at: compilerLocalURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.removeItem(at: compilerLocalURL)
            do {
                try fm.moveItem(at: tempURL, to: compilerLocalURL)
            } catch {
                NSLog("TypeScript 编译器保存失败: \(error.localizedDescription)")
                return
            }
            NSLog("TypeScript 编译器就绪,重新加载扩展")
            DispatchQueue.main.async { PluginManager.shared.loadAll() }
        }.resume()
    }
}

// MARK: - JS 动作

final class PopClipJSAction: PopAction {
    let title: String
    let icon: NSImage?
    private let context: JSContext   // 持有引用,防止 JSContext 被释放
    private let function: JSValue

    init(title: String, icon: NSImage?, context: JSContext, function: JSValue) {
        self.title = title
        self.icon = icon
        self.context = context
        self.function = function
    }

    func perform(with selection: SelectionPayload) {
        DispatchQueue.main.async {
            let popclip = self.context.objectForKeyedSubscript("popclip")
            let input = JSValue(newObjectIn: self.context)
            input?.setObject(selection.text, forKeyedSubscript: "text" as NSString)
            input?.setObject(selection.html ?? "", forKeyedSubscript: "html" as NSString)
            input?.setObject(selection.text, forKeyedSubscript: "matchedText" as NSString)
            // popclip.input 同步更新,两种取文本写法都兼容
            popclip?.setObject(input, forKeyedSubscript: "input" as NSString)

            // PopClip 的 action 签名是 (input, options, context)
            var arguments: [Any] = []
            if let input { arguments.append(input) }
            if let options = popclip?.objectForKeyedSubscript("options") { arguments.append(options) }
            if let ctx = popclip?.objectForKeyedSubscript("context") { arguments.append(ctx) }
            self.function.call(withArguments: arguments)
        }
    }
}
