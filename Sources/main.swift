import Cocoa

// PopBar —— 一个 PopClip 风格的划词工具条
// 入口:菜单栏常驻 (LSUIElement),无 Dock 图标

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
