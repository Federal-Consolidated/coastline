import Foundation

/// Text helpers shared by the GRBL parsers.
enum GRBLText {
    /// The integer at the start of `s` (after whitespace, an optional sign), like C's `stol`.
    static func leadingInteger(_ s: String) -> Int? {
        let trimmed = s.drop(while: { $0.isWhitespace })
        var digits = ""
        for (offset, c) in trimmed.enumerated() {
            if c.isASCII, c.isNumber { digits.append(c) }
            else if offset == 0, c == "-" || c == "+" { digits.append(c) }
            else { break }
        }
        return Int(digits)
    }
}
