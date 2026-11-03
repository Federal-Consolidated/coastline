import Foundation

/// Rewrites a program for the machine without changing where it cuts.
public enum GCodeConvert {
    public struct Result: Sendable {
        public var text: String
        /// What was changed, for the operator ("3 spindle speeds lowered to 8000 RPM").
        public var changes: [String]
    }

    /// Inches (G20) to millimetres (G21). On every line that runs in inches, the length words
    /// (X Y Z I J K R) and the feed (F) are multiplied by 25.4 and G20 becomes G21. Comments and
    /// all other words (G10's L and P, G4's P, S, N…) stay as written; mm lines are unchanged.
    public static func toMillimetres(_ text: String) -> String {
        var inches = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            // Host macros (M100…M114) work on `$#` values, which are always mm: an M101
            // tolerance stays as written.
            if GCodeReader.macro(line) != nil { return String(line) }
            let words = codeWords(line)
            for w in words where w.letter == "G" {
                if let v = Double(w.number), v == 20 { inches = true }
                if let v = Double(w.number), v == 21 { inches = false }
            }
            guard inches || words.contains(where: { $0.letter == "G" && Double($0.number) == 20 }) else { return String(line) }
            return rewrite(line, words) { w in
                if w.letter == "G", Double(w.number) == 20 { return "21" }
                guard "XYZIJKRF".contains(w.letter), let v = Double(w.number) else { return nil }
                return number(v * 25.4)
            }
        }.joined(separator: "\n")
    }

    /// For the machine: spindle speeds above its maximum are lowered to it, and a program end
    /// (M2, M30) becomes a spindle stop (M5), so a guided job carries on after the program, and a
    /// `$L` firmware cycle is removed.
    public static func forCR1(_ text: String, maxRPM: Double) -> Result {
        var lowered = 0, ends = 0, cycles = 0
        let out = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            // `$L` starts a firmware cycle that only some controllers have; the job runs without it.
            if line.trimmingCharacters(in: .whitespaces).uppercased() == "$L" {
                cycles += 1
                return "($L removed)"
            }
            let words = codeWords(line)
            return rewrite(line, words) { w in
                if w.letter == "S", let v = Double(w.number), v > maxRPM {
                    lowered += 1
                    return String(Int(maxRPM))
                }
                if w.letter == "M", let v = Double(w.number), v == 30 || v == 2 {
                    ends += 1
                    return "5"
                }
                return nil
            }
        }.joined(separator: "\n")
        var changes: [String] = []
        if lowered > 0 { changes.append("\(lowered) spindle speed\(lowered == 1 ? "" : "s") above \(Int(maxRPM)) RPM lowered to \(Int(maxRPM)).") }
        if ends > 0 { changes.append("Program end (M30/M2) changed to a spindle stop (M5).") }
        if cycles > 0 { changes.append("Firmware cycle $L removed (not on every controller).") }
        return Result(text: out, changes: changes)
    }

    /// Both, in order: what a loaded program goes through before Coastline runs it.
    public static func prepare(_ text: String, machine: MachineProfile) -> Result {
        let inches = GCodeReader.read(text).usesInches
        var result = forCR1(inches ? toMillimetres(text) : text, maxRPM: machine.spindleRPM.upperBound)
        if inches { result.changes.insert("Converted from inches to millimetres.", at: 0) }
        return result
    }

    // MARK: Text

    struct CodeWord {
        var letter: Character
        /// The number as written, and where it is in the line.
        var number: Substring
        var range: Range<Substring.Index>
    }

    /// The words outside comments, with the position of each number.
    static func codeWords(_ line: Substring) -> [CodeWord] {
        var words: [CodeWord] = []
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "(" {
                guard let close = line[i...].firstIndex(of: ")") else { break }
                i = line.index(after: close)
                continue
            }
            if c == ";" { break }
            if c.isLetter {
                var j = line.index(after: i)
                while j < line.endIndex, line[j] == " " { j = line.index(after: j) }
                let start = j
                var end = j  // after the last character of the number (spaces inside it count, as in GRBL)
                while j < line.endIndex, line[j].isNumber || line[j] == "." || line[j] == "-" || line[j] == "+" || line[j] == " " {
                    if line[j] != " " { end = line.index(after: j) }
                    j = line.index(after: j)
                }
                let number = line[start..<end].filter { $0 != " " }
                if start < end { words.append(CodeWord(letter: Character(c.uppercased()), number: Substring(number), range: start..<end)) }
                i = j > i ? j : line.index(after: i)
                continue
            }
            i = line.index(after: i)
        }
        return words
    }

    /// The line with some numbers replaced (`replacement` returns nil to keep one).
    static func rewrite(_ line: Substring, _ words: [CodeWord], _ replacement: (CodeWord) -> String?) -> String {
        var out = ""
        var cursor = line.startIndex
        for w in words {
            guard let new = replacement(w) else { continue }
            out += line[cursor..<w.range.lowerBound]
            out += new
            cursor = w.range.upperBound
        }
        out += line[cursor...]
        return out
    }

    /// mm with up to 4 decimals (0.1 µm), no trailing zeros.
    static func number(_ v: Double) -> String {
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
}
