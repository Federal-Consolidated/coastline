import MillCore
import Foundation

// millcheck status [/dev/cu.usbmodemXXXX]
// Read-only: connects through MillSession (the same code as Coastline's Control page), prints
// what it sees, then disconnects. It never homes, jogs or sends G-code. Connecting restarts the
// controller, so the machine is in Alarm afterwards, as after any connect.

let args = Array(CommandLine.arguments.dropFirst())
guard args.first == "status" else {
    print("usage: millcheck status [/dev/cu.usbmodemXXXX]")
    exit(2)
}
let found = MillSession.availablePorts()
guard let device = args.count > 1 ? MillDevice(path: args[1], serialNumber: "") : found.first else {
    print("No machine found (USB 2341:0043 or 1A86:7523).")
    exit(1)
}

let session = MillSession()
let start = Date()
session.connect(.device(device))
var lastID = 0
@MainActor func printConsole() {
    for line in session.console(after: lastID) {
        print(String(format: "%7.3f ", line.time.timeIntervalSince(start)) + "\(line.kind) \(line.text)")
        lastID = line.id
    }
}
while Date().timeIntervalSince(start) < 12 {
    printConsole()
    let s = session.snapshot
    if s.link == .connected, s.parserState != nil, s.status != nil { break }
    if s.link == .disconnected, Date().timeIntervalSince(start) > 1 { break }
    usleep(50_000)
}
usleep(600_000)
printConsole()
let s = session.snapshot
print("""

link        \(s.link)
port        \(s.port?.label ?? "-")
banner      \(s.banner ?? "-")
firmware    \(s.firmware ?? "-")
state       \(s.state)   locked \(s.locked)   homed \(s.homed)   silent \(s.silentSince != nil)
position    \(s.status.map { "\($0.machinePosition)" } ?? "-")   work offset \(s.workOffset.map { "\($0)" } ?? "-")
pins        probe \(s.status?.probeTripped ?? false) X \(s.status?.limitX ?? false) Y \(s.status?.limitY ?? false) Z \(s.status?.limitZ ?? false)
modes       \(s.parserState ?? "-")
envelope    \(s.envelope.map { "X \($0.x) Y \($0.y) Z \($0.z)" } ?? "-")
home target \(s.homeTarget.map { "\($0)" } ?? "-")
offsets     \(s.offsets.filter { $0.name.hasPrefix("G5") }.map { "\($0.name) \($0.point)" }.joined(separator: ", "))
gates       home: \(s.gates.home?.text ?? "allowed")
            jog: \(s.gates.jog?.text ?? "allowed")
""")
session.disconnect()
usleep(300_000)
