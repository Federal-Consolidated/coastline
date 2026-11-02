import Foundation

/// Go-to moves from the Control page, as a short program for `MillSession.run` (which checks
/// it again): every target in machine coordinates (G53), and the spindle out first if asked.
public enum GoTo {
    /// What a target's numbers are measured from.
    public enum Frame: String, CaseIterable, Sendable {
        /// The active work offset (G54…G59).
        case work
        case machine
    }

    /// The lines that go to `x`, `y`, `z` (nil: that axis stays). Work targets need the work
    /// offset. With `retractFirst`, the spindle goes fully out (Z to the top of its travel),
    /// then X and Y move, then Z goes to its target; without it, all axes move together.
    public static func lines(x: Double?, y: Double?, z: Double?, frame: Frame, workOffset: Point3?,
                             envelope: MillEnvelope, retractFirst: Bool) -> Result<[String], MillRefusal> {
        guard x != nil || y != nil || z != nil else { return .failure(.blocked("Enter at least one coordinate.")) }
        var offset = Point3.zero
        if frame == .work {
            guard let workOffset else { return .failure(.blocked("The work offset is not known yet. Wait for a status report.")) }
            offset = workOffset
        }
        var target: [Axis: Double] = [:]
        for (axis, value) in [(Axis.x, x), (.y, y), (.z, z)] {
            guard let value else { continue }
            guard value.isFinite else { return .failure(.blocked("\(axis.rawValue) is not a number.")) }
            let machine = value + offset[axis]
            let range = envelope[axis]
            guard range.contains((machine * 1000).rounded() / 1000) else {
                return .failure(.blocked(String(format: "%@ would go to %.3f (machine), outside the travel %.1f … %.1f.",
                                                axis.rawValue, machine, range.lowerBound, range.upperBound)))
            }
            target[axis] = machine
        }
        let f = { (v: Double) in String(format: "%.3f", v) }
        var lines = ["G21", "G90"]
        if retractFirst {
            let top = envelope.z.upperBound
            lines.append("G53G0Z" + f(top))
            let xy = [Axis.x, .y].compactMap { axis in target[axis].map { axis.rawValue + f($0) } }.joined()
            if !xy.isEmpty { lines.append("G53G0" + xy) }
            if let z = target[.z], abs(z - top) >= 0.0005 { lines.append("G53G0Z" + f(z)) }
        } else {
            lines.append("G53G0" + Axis.allCases.compactMap { axis in target[axis].map { axis.rawValue + f($0) } }.joined())
        }
        return .success(lines)
    }
}
