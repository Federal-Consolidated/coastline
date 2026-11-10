import CoastlineCore
import Foundation

/// The machine's table plate, from the machine model: where fixtures stand and how far the
/// stock face comes toward the spindle (model coordinates: X up, Z toward the spindle).
struct MachineTable {
    /// The table's top.
    var topX = -31.12
    /// The table's spindle-side ("north") edge and its back edge (toward you).
    var northZ = -2.4
    var backZ = -67.12
    /// The plate's thickness, mm.
    var thickness = 14.72
    /// The plate's extents along Y; nil: not measured.
    var minimumY: Double?
    var maximumY: Double?
}

extension AppModel {
    var tableGeometry: MachineTable {
        var t = MachineTable()
        if let mm = machineModel { t.topX = mm.tableTopX }
        if let geometry = planningGeometry {
            t.topX = geometry.model.tableTopX
            t.northZ = geometry.supportBounds.maximum.z
            t.backZ = geometry.supportBounds.minimum.z
            t.thickness = t.topX - geometry.tableBounds.minimum.x
            t.minimumY = geometry.tableBounds.minimum.y
            t.maximumY = geometry.tableBounds.maximum.y
        }
        return t
    }
}
