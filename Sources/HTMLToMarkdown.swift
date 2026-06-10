import Foundation

/// 将 HTML 转为 Markdown(覆盖常见标签;无 HTML 时退回纯文本)
enum HTMLToMarkdown {
    static func convert(_ html: String) -> String {
        var s = html
        s = stripBlock(#"(?is)<script[^>]*>.*?</script>"#, from: s)
        s = stripBlock(#"(?is)<style[^>]*>.*?</style>"#, from: s)
        s = replace(#"(?is)<h1[^>]*>(.*?)</h1>"#, in: s, with: "# $1\n\n")
        s = replace(#"(?is)<h2[^>]*>(.*?)</h2>"#, in: s, with: "## $1\n\n")
        s = replace(#"(?is)<h3[^>]*>(.*?)</h3>"#, in: s, with: "### $1\n\n")
        s = replace(#"(?is)<h[4-6][^>]*>(.*?)</h[4-6]>"#, in: s, with: "#### $1\n\n")
        s = replace(#"(?is)<strong[^>]*>(.*?)</strong>"#, in: s, with: "**$1**")
        s = replace(#"(?is)<b[^>]*>(.*?)</b>"#, in: s, with: "**$1**")
        s = replace(#"(?is)<em[^>]*>(.*?)</em>"#, in: s, with: "*$1*")
        s = replace(#"(?is)<i[^>]*>(.*?)</i>"#, in: s, with: "*$1*")
        s = replace(#"(?is)<a[^>]*href=["']([^"']*)["'][^>]*>(.*?)</a>"#, in: s, with: "[$2]($1)")
        s = replace(#"(?is)<blockquote[^>]*>(.*?)</blockquote>"#, in: s, with: "> $1\n\n")
        s = replace(#"(?is)<li[^>]*>(.*?)</li>"#, in: s, with: "- $1\n")
        s = replace(#"(?is)</?ul[^>]*>"#, in: s, with: "\n")
        s = replace(#"(?is)</?ol[^>]*>"#, in: s, with: "\n")
        s = replace(#"(?is)<br\s*/?>"#, in: s, with: "\n")
        s = replace(#"(?is)</p>"#, in: s, with: "\n\n")
        s = replace(#"(?is)<p[^>]*>"#, in: s, with: "")
        s = replace(#"(?is)<div[^>]*>"#, in: s, with: "\n")
        s = replace(#"(?is)</div>"#, in: s, with: "\n")
        s = stripTags(from: s)
        return decodeEntities(s)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripBlock(_ pattern: String, from text: String) -> String {
        text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func stripTags(from text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
