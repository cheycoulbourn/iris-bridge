import Foundation

/// Text on its way to a single printed line. Titles and comments are written by an agent or typed by a
/// creator on a phone: they arrive with newlines in them, with tabs, with the odd terminal escape sequence
/// pasted in from somewhere, and at any length. Printed raw into `iris-bridge inbox` or an MCP tool result,
/// a newline breaks one submission into rows that look like several, an escape sequence recolours the rest of
/// the Terminal session, and a three-thousand-character title buries every other line on the screen.
public enum OneLineText {
    /// Runs of whitespace collapse to one space, control characters and escape sequences are dropped, and
    /// `limit` — when given — is the longest the result may be, the ellipsis included.
    public static func clean(_ text: String, limit: Int? = nil) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == escape { index = endOfEscape(scalars, from: index); continue }
            index += 1
            // Leading whitespace is dropped rather than remembered, and trailing whitespace never arrives:
            // a pending space is only ever written in front of something visible.
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { pendingSpace = !out.isEmpty; continue }
            if isControl(scalar) { continue }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(scalar)
        }
        return truncate(String(out), to: limit)
    }

    private static let escape: Unicode.Scalar = "\u{1B}"

    /// ASCII controls and DEL, plus the C1 block: none of them draw anything, and several move the cursor.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
    }

    /// The index just past an escape sequence beginning at `start`. A CSI run (`ESC [ … m`) ends at its final
    /// byte and an OSC run (`ESC ] … BEL`) at its terminator; anything else is two characters. Dropping the
    /// ESC alone would leave `[31m` on the line, which is worse than either.
    private static func endOfEscape(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start + 1
        guard index < scalars.count else { return index }
        switch scalars[index] {
        case "[":
            index += 1
            while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) { index += 1 }
            return min(index + 1, scalars.count)
        case "]":
            index += 1
            while index < scalars.count {
                if scalars[index].value == 0x07 { return index + 1 }
                if scalars[index] == escape, index + 1 < scalars.count, scalars[index + 1] == "\\" { return index + 2 }
                index += 1
            }
            return index
        default:
            return index + 1
        }
    }

    private static func truncate(_ text: String, to limit: Int?) -> String {
        guard let limit, limit > 0, text.count > limit else { return text }
        return text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
