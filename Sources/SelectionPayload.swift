import Foundation

/// 一次划词取到的内容(纯文本 + 可选 HTML)
struct SelectionPayload {
    let text: String
    let html: String?
    let location: NSPoint
}
