import Foundation
import simd

/// Reads G-code written anywhere (an old .dd job, another CAM program, by hand) into
/// Coastline's `Move`s, so it shows, simulates and times like Coastline's own toolpaths.
///
/// Moves are in the work frame, mm. Machine-coordinate moves (G53) are counted but left out of
/// the preview: placing them needs the work offset, which only the machine knows. Probe moves
/// (G38.x) are drawn to their target; the real move stops at the contact.
public enum GCodeReader {
    public struct Program: Sendable {
        public var moves: [Move] = []
        /// The source line (1-based) of each move.
        public var lineOfMove: [Int] = []
        public var issues: [Issue] = []
        public var lineCount = 0
        /// G53 moves (machine coordinates), not in `moves`.
        public var machineMoves = 0
        /// Work offsets the program selects (54…59).
        public var workOffsets: Set<Int> = []
        /// Spindle speeds used while the spindle is on.
        public var spindleSpeeds: Set<Double> = []
        public var usesInches = false
        public var probes = 0
        /// G10 lines: the program sets work offsets itself (probing routines do).
        public var offsetWrites = 0
        /// Host M-codes (M100…M114): run by Coastline, not the controller.
        public var macros: Set<Int> = []
        /// `$` lines: `$H` (homing), `$X`, `$J=`…
        public var systemCommands: [String] = []
        /// Moves in incremental mode (G91). An air cut (Z raised) is only safe without them.
        public var relativeMoves = 0
        /// Seconds of G4 dwell.
        public var dwell = 0.0
        /// Moves that are probe moves (G38.x): drawn to their target, the real move stops sooner.
        public var probeMoves: Set<Int> = []
        /// Moves whose start is not known: the first one, and those after a G53 move or a probe.
        public var unknownStart: Set<Int> = []
        /// Moves that don't start where the move before ended (a `G10 L20` set the position
        /// between them): move index → its start.
        public var restarts: [Int: Vec3] = [:]

        /// Where move `k` starts (nil for the first).
        public func start(of k: Int) -> SIMD3<Double>? {
            if let r = restarts[k] { return SIMD3(r.x, r.y, r.z) }
            return k > 0 ? moves[k - 1].position : nil
        }
        /// Box of the feed moves (not rapids), work frame. Plain `Vec3`s, not SIMD: the result
        /// crosses `await` in the app (over-aligned SIMD values trip a Swift runtime bug there).
        public var cutMin: Vec3?
        public var cutMax: Vec3?

        /// Feed-move length in mm.
        public var cutLength: Double {
            var length = 0.0
            var previous: SIMD3<Double>?
            for move in moves {
                defer { previous = move.position }
                guard let p = previous, move.role != .rapid else { continue }
                length += simd_distance(p, move.position)
            }
            return length
        }
    }

    /// Words a line may carry, after comments are removed.
    struct Word {
        var letter: Character
        var value: Double
        var text: Substring
    }

    /// Splits one line into words. Comments `( … )` and `; …` are dropped; `nil` if a word
    /// has no number.
    static func words(_ line: Substring) -> [Word]? {
        var result: [Word] = []
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "(" {
                guard let close = line[i...].firstIndex(of: ")") else { return result }
                i = line.index(after: close)
                continue
            }
            if c == ";" { break }
            if c == " " || c == "\t" || c == "\r" || c == "%" {
                i = line.index(after: i)
                continue
            }
            guard c.isLetter else { return nil }
            var j = line.index(after: i)
            while j < line.endIndex, line[j] == " " { j = line.index(after: j) }
            let start = j
            // GRBL drops every space before it parses, so `Z- 0.15` is `Z-0.15`.
            var end = j
            while j < line.endIndex, line[j].isNumber || line[j] == "." || line[j] == "-" || line[j] == "+" || line[j] == " " {
                if line[j] != " " { end = line.index(after: j) }
                j = line.index(after: j)
            }
            let number = line[start..<end].filter { $0 != " " }
            guard !number.isEmpty, let value = Double(number) else { return nil }
            result.append(Word(letter: Character(c.uppercased()), value: value, text: line[start..<end]))
            i = j
        }
        return result
    }

    public static func read(_ text: String) -> Program {
        var p = Program()
        var issued = Set<String>()
        func issue(_ severity: Issue.Severity, _ line: Int, _ message: String) {
            guard issued.insert(String(message.prefix(48))).inserted else { return }
            p.issues.append(Issue(severity, "Line \(line): \(message)"))
        }

        var inches = false, relative = false, spindleOn = false
        var motion = 0.0  // 0, 1, 2, 3 or 38.x
        var feed = 0.0  // mm/min
        var rpm = 0.0
        // Unknown until the program says: X/Y start at 0, Z above the work.
        var pos = SIMD3<Double>(0, 0, 10)
        // Per axis: the position is the program's own, not the guess above or a stale one after a
        // G53 move, a probe or a changed work offset.
        var known = [false, false, false]
        var wcs = 54
        var moved = false  // a G10 L20 changed `pos` since the last move

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        p.lineCount = lines.count
        for (index, raw) in lines.enumerated() {
            let n = index + 1
            let trimmed = raw.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("$") {
                p.systemCommands.append(String(trimmed.prefix { !$0.isWhitespace && $0 != "(" }))
                continue
            }
            // Host macros (`M100 G56XG57XG55X`) have their own argument syntax.
            if let m = macro(raw) {
                p.macros.insert(m)
                continue
            }
            guard let words = words(raw) else {
                issue(.error, n, "can't read \"\(raw.trimmingCharacters(in: .whitespaces))\".")
                continue
            }
            if words.isEmpty { continue }
            var machine = false
            var axes: [Character: Double] = [:]
            var arc: [Character: Double] = [:]
            var dwell: Double?
            var setsOffset = false
            for w in words {
                switch w.letter {
                case "G":
                    let g = (w.value * 10).rounded() / 10
                    switch g {
                    case 0, 1, 2, 3: motion = g
                    case 38.2, 38.3, 38.4, 38.5: motion = g; p.probes += 1
                    case 20: inches = true; p.usesInches = true
                    case 21: inches = false
                    case 90: relative = false
                    case 91: relative = true
                    case 53: machine = true
                    case 54, 55, 56, 57, 58, 59: p.workOffsets.insert(Int(g)); wcs = Int(g)
                    case 4: dwell = 0
                    case 10: setsOffset = true; p.offsetWrites += 1
                    case 17, 40, 49, 80, 90.1, 91.1, 94, 61: break
                    case 18, 19: issue(.error, n, "arcs outside the XY plane (G\(Int(g))) are not supported.")
                    case 93: issue(.error, n, "inverse-time feed (G93) is not supported.")
                    case 28, 30: issue(.warning, n, "G\(Int(g)) moves to a stored position Coastline can't show.")
                    case 92: issue(.warning, n, "G92 offsets are not shown.")
                    case 92.1: break  // clears G92
                    case 43.1: break
                    default: issue(.warning, n, "G\(w.text) is not a machine command.")
                    }
                case "M":
                    let m = Int(w.value)
                    switch m {
                    case 3, 4: spindleOn = true
                    case 5, 2, 30: spindleOn = false
                    case 7, 8, 9, 17, 18: break
                    case 0, 1: issue(.warning, n, "M\(m) pauses the program.")
                    case 6: issue(.warning, n, "M6 tool change: the machine changes tools by hand.")
                    case 100...114: p.macros.insert(m)
                    default: issue(.warning, n, "M\(m) is not a machine command.")
                    }
                case "X", "Y", "Z": axes[w.letter] = w.value
                case "I", "J", "K", "R": arc[w.letter] = w.value
                case "F": feed = w.value * (inches ? 25.4 : 1)
                case "S": rpm = w.value
                case "P": if dwell != nil { dwell = w.value }  // G4 P: seconds (G10 P is an offset number)
                case "L", "N", "T", "H", "D", "Q": break
                default: issue(.warning, n, "word \(w.letter) is not used by the machine.")
                }
            }
            if spindleOn, rpm > 0 { p.spindleSpeeds.insert(rpm) }
            if let dwell, !setsOffset, axes.isEmpty {
                p.dwell += dwell
                continue
            }
            if setsOffset {
                // G10 L20 on the active offset: the named axes are now at the values given.
                // G10 L2 (or another offset): the work position of those axes is no longer known.
                let l = words.first { $0.letter == "L" }?.value, offset = words.first { $0.letter == "P" }?.value
                let scale = inches ? 25.4 : 1
                for (letter, value) in axes {
                    let k = letter == "X" ? 0 : (letter == "Y" ? 1 : 2)
                    if l == 20, let offset, Int(offset) + 53 == wcs {
                        pos[k] = value * scale
                        known[k] = true
                        moved = true
                    } else if l == 2, let offset, Int(offset) + 53 == wcs {
                        known[k] = false
                    }
                }
                continue
            }
            guard !axes.isEmpty else { continue }
            if machine {
                p.machineMoves += 1
                for letter in axes.keys { known[letter == "X" ? 0 : (letter == "Y" ? 1 : 2)] = false }
                continue
            }
            if relative { p.relativeMoves += 1 }
            let scale = inches ? 25.4 : 1
            var target = pos
            for (letter, value) in axes {
                let k = letter == "X" ? 0 : (letter == "Y" ? 1 : 2)
                target[k] = relative ? pos[k] + value * scale : value * scale
            }
            var move: Move
            switch motion {
            case 2, 3:
                var i = (arc["I"] ?? 0) * scale, j = (arc["J"] ?? 0) * scale
                if let r = arc["R"] {
                    guard let centre = arcCentre(from: pos, to: target, radius: r * scale, clockwise: motion == 2) else {
                        issue(.error, n, "arc radius R\(r) is too small for its end point.")
                        pos = target
                        continue
                    }
                    i = centre.x - pos.x
                    j = centre.y - pos.y
                }
                move = Move(.cut, motion == 2 ? .arcCW : .arcCCW, x: target.x, y: target.y, z: target.z, i: i, j: j, feed: feed)
            case 0:
                move = Move(.rapid, x: target.x, y: target.y, z: target.z)
            default:
                let plunge = target.x == pos.x && target.y == pos.y && target.z < pos.z
                move = Move(plunge || motion >= 38 ? .plunge : .cut, x: target.x, y: target.y, z: target.z, feed: feed)
                if motion >= 1, feed <= 0 { issue(.error, n, "a feed move with no feed rate (F).") }
            }
            if move.role != .rapid {
                let lo = p.cutMin.map { simd_min(SIMD3($0.x, $0.y, $0.z), target) } ?? target
                let hi = p.cutMax.map { simd_max(SIMD3($0.x, $0.y, $0.z), target) } ?? target
                p.cutMin = Vec3(lo.x, lo.y, lo.z)
                p.cutMax = Vec3(hi.x, hi.y, hi.z)
            }
            if known.contains(false) { p.unknownStart.insert(p.moves.count) }
            if moved { p.restarts[p.moves.count] = Vec3(pos.x, pos.y, pos.z); moved = false }
            for letter in axes.keys {
                let k = letter == "X" ? 0 : (letter == "Y" ? 1 : 2)
                // A probe stops at the contact; a relative move from an unknown position stays unknown.
                known[k] = motion >= 38 ? false : (relative ? known[k] : true)
            }
            if motion >= 38 { p.probeMoves.insert(p.moves.count) }
            p.moves.append(move)
            p.lineOfMove.append(n)
            pos = target
        }
        return p
    }

    /// The M-code of a host macro line (M100…M114), which Coastline runs itself.
    static func macro(_ line: Substring) -> Int? {
        let code = line.drop { $0 == " " || $0 == "\t" }.uppercased()
        guard code.hasPrefix("M1"), let m = Int(code.dropFirst().prefix { $0.isNumber }), (100...114).contains(m) else { return nil }
        return m
    }

    /// The centre of an R-format arc in the XY plane (positive R: the short way).
    static func arcCentre(from a: SIMD3<Double>, to b: SIMD3<Double>, radius r: Double, clockwise: Bool) -> SIMD2<Double>? {
        let p = SIMD2(a.x, a.y), q = SIMD2(b.x, b.y)
        let chord = q - p
        let d = simd_length(chord)
        guard d > 0, abs(r) >= d / 2 - 1e-9 else { return nil }
        let h = sqrt(max(0, r * r - d * d / 4))
        let mid = (p + q) / 2
        let normal = SIMD2(-chord.y, chord.x) / d
        // CW with positive R: centre on the right of the chord.
        let side: Double = (clockwise ? -1 : 1) * (r < 0 ? -1 : 1)
        return mid + normal * h * side
    }
}
