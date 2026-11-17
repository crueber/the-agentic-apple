import SwiftUI

/// Renders `backtick` spans in monospaced type. Plain splitting, no Markdown
/// parsing, so untrusted text can't inject links or formatting.
enum InlineCode {
    static func text(_ string: String, size: CGFloat) -> Text {
        let parts = string.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return Text(string).font(.system(size: size)) }
        var out = Text("")
        for (i, part) in parts.enumerated() {
            let piece = String(part)
            if i % 2 == 1 && i < parts.count - 1 {
                out = out + Text(piece).font(.system(size: size - 0.5, design: .monospaced))
            } else {
                // An unmatched trailing backtick is kept literally.
                let literal = (i % 2 == 1) ? "`" + piece : piece
                out = out + Text(literal).font(.system(size: size))
            }
        }
        return out
    }
}
