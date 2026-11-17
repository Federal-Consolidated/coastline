import Foundation

/// Raw byte transport to the mill. Implemented by `POSIXSerialPort` for real hardware and by
/// `MockGRBL` for tests and the app's simulated-mill mode.
public protocol SerialTransport: AnyObject, Sendable {
    func open() throws
    func close()
    /// Writes all bytes or throws `MillError.failedWrite`.
    func write(_ bytes: [UInt8]) throws
    /// Returns and removes all bytes received so far (never blocks).
    func readAvailable() -> [UInt8]
    var isOpen: Bool { get }
}

/// A USB serial device that looks like a supported mill (`CNCMill` in the original).
public struct MillDevice: Hashable, Sendable, Identifiable {
    public var path: String
    public var serialNumber: String
    /// The USB vendor and product ID, `2341:0043` (empty when not known), for diagnostics.
    public var usbID: String
    public var id: String { path + "#" + serialNumber }

    public init(path: String, serialNumber: String, usbID: String = "") {
        self.path = path
        self.serialNumber = serialNumber
        self.usbID = usbID
    }

    /// One line for the console: where it is, which USB device and its serial number.
    public var diagnostics: String {
        "\(path)" + (usbID.isEmpty ? "" : " · USB \(usbID)") + (serialNumber.isEmpty || serialNumber == path ? " · no serial number" : " · serial \(serialNumber)")
    }
}
