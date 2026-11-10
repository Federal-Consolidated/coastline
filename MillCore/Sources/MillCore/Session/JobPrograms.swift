import Foundation

/// Checks a guided job's program before it runs: the words a job may use (moves, arcs, probing,
/// work offsets, the spindle, `$H`, `$#`, Coastline's M100 and M101), the spindle limit, and the machine-
/// coordinate moves against the envelope. Moves in work coordinates are left to the
/// controller's soft limits: probing changes the work offset while the program runs.
public enum JobProgramCheck {
    public struct Program: Sendable, Equatable {
        /// The lines as they are sent (comments and spaces removed).
        public var lines: [String]
        /// The program homes first (`$H`): it may start from Alarm, before the machine is homed.
        public var startsWithHome: Bool
    }

    static let codes: Set<String> = ["G0", "G1", "G2", "G3", "G4", "G10", "G17", "G21", "G40", "G38.2", "G38.3", "G53",
                                     "G54", "G55", "G56", "G57", "G58", "G59", "G90", "G91", "G91.1", "G92.1", "G94",
                                     "M3", "M4", "M5", "M9"]

    public static func clean(_ lines: [String], settings: MillSettings, envelope: MillEnvelope) -> Result<Program, MillRefusal> {
        let maxRPM = settings.values[30] ?? 8000
        var cleaned: [String] = []
        for (index, raw) in lines.enumerated() {
            let n = index + 1
            let line = raw.replacingOccurrences(of: #"\(.*?\)|;.*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
                .trimmingCharacters(in: .whitespaces).uppercased()
            if line.isEmpty { continue }
            if line == "$H" { cleaned.append(line); continue }
            // GRBL answers `$#` only when idle: G4 P0 waits for the moves to finish first.
            if line == "$#" { cleaned += ["G4P0", line]; continue }
            if line.hasPrefix("$") { return .failure(.blocked("Line \(n): \(raw) is not allowed in a job program.")) }
            if line.hasPrefix("M101") {
                guard M101.parse(line) != nil else { return .failure(.blocked("Line \(n): M101 needs three offsets, an axis and a tolerance, e.g. M101 G57 G58 G59 X 0.152.")) }
                cleaned.append(line)
                continue
            }
            if line.hasPrefix("M100") {
                guard M100.parse(line) != nil else { return .failure(.blocked("Line \(n): M100 needs three offsets, e.g. M100 G56X G57X G55X.")) }
                cleaned.append(line)
                continue
            }
            let words = line.matches(of: /([A-Z])([+-]?(?:\d+\.?\d*|\.\d+))/).map { (String($0.output.1), Double($0.output.2) ?? .nan) }
            guard words.map({ "\($0.0)" }).count > 0,
                  line.matches(of: /([A-Z])([+-]?(?:\d+\.?\d*|\.\d+))/).map({ String($0.output.0) }).joined() == line,
                  words.allSatisfy({ "GMXYZIJKRFSPL".contains($0.0) && $0.1.isFinite }) else {
                return .failure(.blocked("Line \(n) is not allowed in a job program: \(raw)"))
            }
            for (letter, value) in words where letter == "G" || letter == "M" {
                let code = "\(letter)\(String(format: "%g", value))"
                if code == "G20" { return .failure(.blocked("Line \(n): the program is in inches (G20). Convert it to mm first.")) }
                guard codes.contains(code) else { return .failure(.blocked("Line \(n): \(code) is not allowed in a job program.")) }
            }
            if let s = words.first(where: { $0.0 == "S" })?.1, s > maxRPM {
                return .failure(.blocked(String(format: "Line %d: S%.0f is above the spindle's %.0f RPM.", n, s, maxRPM)))
            }
            if words.contains(where: { $0 == ("G", 10) }) {
                let l = words.first { $0.0 == "L" }?.1, p = words.first { $0.0 == "P" }?.1
                guard l == 2 || l == 20, let p, (1.0...6.0).contains(p), p.rounded() == p else {
                    return .failure(.blocked("Line \(n): only G10 L2/L20 P1–P6 (work offsets) are allowed."))
                }
            }
            // G53 targets are machine coordinates: they must be inside the envelope.
            if words.contains(where: { $0 == ("G", 53) }) {
                for (letter, value) in words {
                    guard let axis = Axis(letter: Character(letter)), "XYZ".contains(letter) else { continue }
                    if !envelope[axis].contains((value * 1000).rounded() / 1000) {
                        return .failure(.blocked(String(format: "Line %d: G53 %@%.3f is outside the travel.", n, letter, value)))
                    }
                }
            }
            cleaned.append(line)
        }
        return .success(Program(lines: cleaned, startsWithHome: cleaned.first == "$H"))
    }
}

/// the original software's `M100`: the midpoint of two work-offset values, written into a third.
/// `M100 G56X G57X G55X`: G55 X = (G56 X + G57 X) / 2. Coastline runs it, not the controller.
public enum M100 {
    public struct Call: Sendable, Equatable {
        public var a: (wcs: Int, axis: Axis)
        public var b: (wcs: Int, axis: Axis)
        public var destination: (wcs: Int, axis: Axis)

        public static func == (l: Call, r: Call) -> Bool {
            l.a == r.a && l.b == r.b && l.destination == r.destination
        }
    }

    /// From the cleaned line (`M100G56XG57XG55X`).
    public static func parse(_ line: String) -> Call? {
        let refs = line.dropFirst(4).matches(of: /G5([4-9])([XYZ])/).compactMap { m -> (Int, Axis)? in
            guard let k = Int(m.output.1), let axis = Axis(letter: Character(String(m.output.2))) else { return nil }
            return (50 + k, axis)  // "G5" + digit
        }
        guard refs.count == 3, line.dropFirst(4).replacingOccurrences(of: #"G5[4-9][XYZ]"#, with: "", options: .regularExpression).isEmpty else {
            return nil
        }
        return Call(a: refs[0], b: refs[1], destination: refs[2])
    }

    /// The offset of `wcs` on `axis` in a `$#` reply.
    static func value(_ offsets: [MillOffset], _ ref: (wcs: Int, axis: Axis)) -> Double? {
        offsets.first { $0.name == "G\(ref.wcs)" }?.point[ref.axis]
    }
}

/// the original software's `M101`: a tolerance check on probed work offsets. `M101 G57 G58 G59 X 0.152`
/// stops the program when the X values of G57, G58 and G59 spread by 0.152 mm or more (the part
/// sits out of tolerance in the jig). Coastline runs it, not the controller.
public enum M101 {
    public struct Call: Sendable, Equatable {
        public var offsets: [Int]
        public var axis: Axis
        public var tolerance: Double
    }

    /// From the cleaned line (`M101G57G58G59X0.152`).
    public static func parse(_ line: String) -> Call? {
        guard let m = line.wholeMatch(of: /M101G5([4-9])G5([4-9])G5([4-9])([XYZ])(\d*\.?\d+)/),
              let axis = Axis(letter: Character(String(m.output.4))), let tolerance = Double(m.output.5), tolerance > 0 else { return nil }
        let offsets = [m.output.1, m.output.2, m.output.3].compactMap { Int($0) }.map { 50 + $0 }
        return Call(offsets: offsets, axis: axis, tolerance: tolerance)
    }

    /// `nil` when the values are inside the tolerance, else why not. All three must be reported.
    public static func problem(_ call: Call, _ offsets: [MillOffset]) -> String? {
        let values = call.offsets.compactMap { wcs in offsets.first { $0.name == "G\(wcs)" }?.point[call.axis] }
        guard values.count == 3, let lo = values.min(), let hi = values.max() else {
            return "the controller did not report " + call.offsets.map { "G\($0)" }.joined(separator: ", ") + "."
        }
        guard hi - lo < call.tolerance else {
            return String(format: "the part is out of tolerance: %@ %@ spread %.3f mm (%@), the limit is %.3f mm.",
                          call.offsets.map { "G\($0)" }.joined(separator: "/"), call.axis.rawValue, hi - lo,
                          values.map { String(format: "%.3f", $0) }.joined(separator: ", "), call.tolerance)
        }
        return nil
    }
}
