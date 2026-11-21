import Foundation
import IOKit
import IOKit.serial
import IOKit.usb

/// Finds plugged-in mills. Port of `MillFinder_osx.cpp`.
public enum PortFinder {
    /// USB vendor/product IDs of the mill's controller: the mill's Arduino boards
    /// (2341:0043 and 2341:003E) and CH340 adapters (1A86:7523).
    static let acceptedIDs: Set<[Int]> = [[0x2341, 0x0043], [0x2341, 0x003E], [0x1A86, 0x7523]]

    /// Device-path prefixes. The original only accepted `/dev/cu.usbmodem`, which misses CH340
    /// adapters (they appear as `cu.usbserial-*` / `cu.wchusbserial*`). Deliberate fix.
    static let pathPrefixes = ["/dev/cu.usbmodem", "/dev/cu.usbserial", "/dev/cu.wchusbserial"]

    public static func availableMills() -> [MillDevice] {
        var mills: [MillDevice] = []
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return mills }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return mills
        }
        defer { IOObjectRelease(iterator) }

        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard let path = stringProperty(device, kIOCalloutDeviceKey, searchParents: false),
                  pathPrefixes.contains(where: { path.hasPrefix($0) }) else { continue }
            let vendor = intProperty(device, "idVendor")
            let product = intProperty(device, "idProduct")
            guard acceptedIDs.contains([vendor, product]) else { continue }
            // A serial number helps tell two mills apart but is not required: some boards and
            // clones report none. The path stands in for it then.
            let serial = stringProperty(device, kUSBSerialNumberString, searchParents: true) ?? ""
            mills.append(MillDevice(path: path, serialNumber: serial.isEmpty ? path : serial,
                                    usbID: String(format: "%04X:%04X", vendor, product)))
        }
        return mills
    }

    private static func property(_ device: io_object_t, _ key: String, searchParents: Bool) -> CFTypeRef? {
        if searchParents {
            return IORegistryEntrySearchCFProperty(
                device, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        }
        return IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func stringProperty(_ device: io_object_t, _ key: String, searchParents: Bool) -> String? {
        property(device, key, searchParents: searchParents) as? String
    }

    private static func intProperty(_ device: io_object_t, _ key: String) -> Int {
        (property(device, key, searchParents: true) as? NSNumber)?.intValue ?? 0
    }
}
