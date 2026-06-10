# PopBar

PopClip 风格的 macOS 划词工具条。选中文本 → 光标旁弹出浮动工具条 → 一键执行动作。

纯 Swift / AppKit 实现，无第三方依赖，单二进制约 200 KB，**无 Xcode 也能构建**（只需 Command Line Tools）。

```
划词检测              取词                    浮条                 动作
─────────            ─────────              ─────────            ─────────
全局鼠标监听     →    AX API 读选区      →   非激活 NSPanel   →   内置动作
(mouseUp +           (失败则模拟 ⌘C          (orderFront-         + 扩展插件
 拖选/双击判断)        并恢复剪贴板)           Regardless)          (url/shell/applescript)
```

## 功能

### 内置动作

| 动作 | 说明 |
|------|------|
| 复制 | 选中文本写入剪贴板 |
| 翻译 | **系统离线翻译**（Translation 框架，英 → 简体中文），结果显示在浮窗里，光标移开自动关闭，不跳浏览器、不联网泄露文本 |
| Claude | 打开 claude.ai 新对话，自动带上"请翻译如下文本：" + 选中内容 |

### 扩展系统

支持两种扩展格式，放入 `~/Library/Application Support/PopBar/Extensions/` 即可（菜单栏 → 重新加载扩展）：

**1. PopBar 原生格式（`.popext`）**

```
MyPlugin.popext/
├── manifest.json     # 必需
├── icon.png          # 可选
└── run.sh            # type=shell 时
```

```jsonc
// URL 型:{text} 替换为 URL 编码后的选中文本
{ "name": "DeepL", "type": "url",
  "url": "https://www.deepl.com/translator#auto/zh/{text}" }

// Shell 型:选中文本通过环境变量 POPBAR_TEXT 传入
{ "name": "转大写", "type": "shell", "script": "run.sh" }
```

**2. PopClip 官方扩展（`.popclipext`）兼容**

可直接安装 [popclip.app/extensions](https://www.popclip.app/extensions/) 的扩展包：

- 配置解析：`Config.plist` / `Config.json` / 简单结构的 `Config.yaml`（多个共存时合并）
- 动作类型：`url`（`***` 占位符）、`shell script file`（`POPCLIP_TEXT` 环境变量、`interpreter` 字段）、`applescript` / `applescript file`（`{popclip text}`、`{popclip option x}` 占位符替换）
- `options` 取默认值，`requirements` 中的 `option-x=y` 按默认值筛选动作
- 暂不支持：JavaScript 型扩展、设置界面、签名校验

### 安装扩展的三种方式

1. **双击安装**：下载 `.popclipextz` / `.popextz` 后右键 → 打开方式 → PopBar，确认后自动解压安装
2. **拖放安装**：把压缩包或扩展文件夹直接丢进 Extensions 目录，下次加载时自动解压
3. **网页一键安装**：网页放链接 `popbar://install?url=<HTTPS 下载地址>`，点击唤起 PopBar 确认安装

### 其他

- 菜单栏常驻（无 Dock 图标），随时打开扩展目录 / 重载扩展
- 开机自启动开关（`SMAppService`，出现在 系统设置 → 登录项）
- 辅助功能授权后自动生效，无需重启 App

## 安装

### 方式一：下载 Release

1. 下载 [Releases](../../releases) 中的 `PopBar.app.zip`，解压后拖入 `/Applications`
2. 首次打开会被 Gatekeeper 拦截（自签名应用）：右键 App → 打开，或在 系统设置 → 隐私与安全性 中点"仍要打开"
3. 按提示授予 **辅助功能** 权限（系统设置 → 隐私与安全性 → 辅助功能 → 打开 PopBar 开关）
4. 选中任意文字试试

### 方式二：源码构建（无需 Xcode）

```bash
git clone https://github.com/<you>/PopBar.git && cd PopBar
./build.sh   # 编译 → 组装 .app → 签名 → 安装到 /Applications → 启动
```

`build.sh` 默认用名为 `PopBar Code Signing` 的自签名证书签名（保证 TCC 授权在更新后不失效）。没有该证书时可改成 ad-hoc 签名：把脚本里的 `IDENTITY` 改为 `-`。

> 要求 macOS 15+（系统翻译用到 Translation 框架）。首次使用翻译时按提示下载离线语言模型（英语、简体中文）。

## 资源占用

设计上**空闲时零轮询**：

- 划词检测是事件驱动的全局鼠标监听，只在"拖选超过 4pt 或双击"后才尝试取词（优先 AX API，失败才模拟 ⌘C 且会恢复剪贴板）
- 翻译浮窗的鼠标位置检测（0.25s）只在浮窗可见期间运行，关闭即停
- 辅助功能授权轮询（2s）只在未授权时运行，授权后立即停止
- 工具条的自动隐藏计时器为 6 秒一次性触发

## 安全说明

- shell / AppleScript 型扩展可以在你的电脑上执行任意代码，**只安装信任来源的扩展**；所有安装路径都会弹确认框，网络安装强制 HTTPS
- 密码框等安全输入字段无法取词（系统保证），也不会弹条
- App 未开沙盒（辅助功能 API 的要求），不会出现在 Mac App Store

## 项目结构

```
Sources/
├── main.swift              # 入口(菜单栏 accessory app)
├── AppDelegate.swift       # 权限引导、菜单、扩展安装入口、开机自启动
├── SelectionMonitor.swift  # 划词检测 + 双路取词(AX / ⌘C)
├── PopupPanel.swift        # 非激活浮动工具条
├── Actions.swift           # 内置动作:复制 / 翻译 / Claude
├── TranslatePanel.swift    # 系统离线翻译浮窗(Translation 框架)
├── PluginManager.swift     # .popext 加载 + 压缩包自动解压
├── PopClipSupport.swift    # PopClip .popclipext 兼容层
└── PluginInstaller.swift   # popbar:// 一键安装 + 本地包安装
```

## License

MIT
