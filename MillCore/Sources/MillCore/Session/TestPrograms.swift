import Foundation

/// Small built-in programs for checking a real machine from the Control page.
public enum TestProgram: String, CaseIterable, Identifiable, Sendable {
    case korobeiniki

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .korobeiniki: "Tetris Song (Korobeiniki)"
        }
    }

    public var detail: String {
        switch self {
        case .korobeiniki:
            "Plays the Tetris theme on the Y stepper. Y goes to −30, moves about ±1.3 mm for 28 s, then goes back to −0.5. The spindle stays off; X and Z do not move."
        }
    }

    public var lines: [String] {
        switch self {
        case .korobeiniki: Self.song()
        }
    }

    /// A stepper sings at its step rate, f = F / 60 × steps per mm, so each note is a G1 move at
    /// F = f × 60 / 400 (`$101`), and its length sets how long the note lasts. The direction
    /// changes on every note, so the gantry stays near Y −30. Same as `scripts/make-song.py`.
    private static func song() -> [String] {
        let stepsPerMM = 400.0
        let beat = 60.0 / 120  // 120 BPM
        let notes: [String: Double] = ["A4": 440.00, "B4": 493.88, "C5": 523.25, "D5": 587.33,
                                       "E5": 659.26, "F5": 698.46, "G5": 783.99, "A5": 880.00]
        // (note, beats); nil is a rest.
        let partA: [(String?, Double)] = [
            ("E5", 1), ("B4", 0.5), ("C5", 0.5), ("D5", 1), ("C5", 0.5), ("B4", 0.5),
            ("A4", 1), ("A4", 0.5), ("C5", 0.5), ("E5", 1), ("D5", 0.5), ("C5", 0.5),
            ("B4", 1.5), ("C5", 0.5), ("D5", 1), ("E5", 1),
            ("C5", 1), ("A4", 1), ("A4", 1), (nil, 1),
        ]
        let partB: [(String?, Double)] = [
            (nil, 0.5), ("D5", 1), ("F5", 0.5), ("A5", 1), ("G5", 0.5), ("F5", 0.5),
            ("E5", 1.5), ("C5", 0.5), ("E5", 1), ("D5", 0.5), ("C5", 0.5),
            ("B4", 1), ("B4", 0.5), ("C5", 0.5), ("D5", 1), ("E5", 1),
            ("C5", 1), ("A4", 1), ("A4", 1), (nil, 1),
        ]
        var lines = ["G21", "G90", "M5", "G53 G1 Y-30.000 F1000", "G4 P0.5", "G91"]
        var direction = -1.0
        for (note, beats) in partA + partB + partA {
            let seconds = beats * beat
            guard let note, let frequency = notes[note] else {
                lines.append(String(format: "G4 P%.3f", seconds))
                continue
            }
            let feed = frequency * 60 / stepsPerMM
            lines.append(String(format: "G1 Y%.3f F%.2f", direction * feed / 60 * seconds, feed))
            direction = -direction
        }
        lines += ["G90", "G53 G1 Y-0.500 F1000"]
        return lines
    }
}

/// Checks a test program before it runs: only simple words, and every position inside the
/// envelope, worked out from where the machine is now. Same rules as `scripts/mill-move-test.py`.
public enum ProgramCheck {
    static let allowedCodes: Set<String> = ["G0", "G1", "G4", "G21", "G53", "G90", "G91", "M5"]

    /// Returns the lines as they will be sent (comments and spaces removed), or the problem.
    public static func clean(_ lines: [String], start: Point3, envelope: MillEnvelope) -> Result<[String], MillRefusal> {
        var position = start
        var relative = false
        var cleaned: [String] = []
        for (index, raw) in lines.enumerated() {
            let number = index + 1
            let line = raw.replacingOccurrences(of: #"\(.*?\)|;.*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespaces).uppercased()
            if line.isEmpty { continue }
            let words = line.matches(of: /([A-Z])([+-]?(?:\d+\.?\d*|\.\d+))/).map { (String($0.output.1), Double($0.output.2) ?? .nan) }
            let rebuilt = line.matches(of: /([A-Z])([+-]?(?:\d+\.?\d*|\.\d+))/).map { String($0.output.0) }.joined()
            guard rebuilt == line, words.allSatisfy({ "GMXYZFP".contains($0.0) && $0.1.isFinite }) else {
                return .failure(.blocked("Line \(number) is not allowed in a test program: \(raw)"))
            }
            let codes = Set(words.filter { $0.0 == "G" || $0.0 == "M" }.map { "\($0.0)\(String(format: "%g", $0.1))" })
            if let bad = codes.subtracting(allowedCodes).sorted().first {
                return .failure(.blocked("Line \(number): \(bad) is not allowed in a test program."))
            }
            relative = (relative || codes.contains("G91")) && !codes.contains("G90")
            let axes = words.filter { "XYZ".contains($0.0) }
            if !axes.isEmpty, relative == codes.contains("G53") {
                return .failure(.blocked("Line \(number): absolute moves must use G53, relative moves must not."))
            }
            for (letter, value) in axes {
                guard let axis = Axis(letter: Character(letter)) else { continue }
                position[axis] = relative ? position[axis] + value : value
                let range = envelope[axis]
                let p = (position[axis] * 10_000).rounded() / 10_000
                if !range.contains(p) {
                    return .failure(.blocked(String(format: "Line %d: %@ would go to %.3f, outside %.1f … %.1f.",
                                                    number, letter, position[axis], range.lowerBound, range.upperBound)))
                }
            }
            cleaned.append(line)
        }
        return .success(cleaned)
    }
}
