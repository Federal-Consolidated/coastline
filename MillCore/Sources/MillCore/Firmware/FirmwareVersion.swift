import Foundation

/// Firmware identification from `$I`, e.g. `[grbl:1.1g XY:3A PCB:3B VFD:3A YMD:20240318]`, where
/// `XY:3A` is the machine family's own tag and version (each maker's fork uses its own letters).
/// Port of `FirmwareVersion` (`src/Mill/Firmware/FirmwareVersion.cpp`).
public struct FirmwareVersion: Equatable, Sendable {
    public var grbl = ""
    /// Build date YYYYMMDD; used for `min_fw_version` checks.
    public var ymd = ""
    /// The machine family's tag (the first field that is not grbl, PCB, VFD or YMD) and its version.
    public var family = ""
    public var familyVersion = ""
    public var pcb = ""
    public var vfd = "3A"

    public init(grbl: String = "", ymd: String = "", family: String = "", familyVersion: String = "", pcb: String = "", vfd: String = "3A") {
        self.grbl = grbl
        self.ymd = ymd
        self.family = family
        self.familyVersion = familyVersion
        self.pcb = pcb
        self.vfd = vfd
    }

    /// Strips the surrounding brackets and reads `key:value` words. Also accepts the old
    /// `<Grbl 1.1, XY 2>`-style comma format.
    public static func parse(_ response: String) -> FirmwareVersion? {
        guard response.count >= 2 else { return nil }
        let line = String(response.dropFirst().dropLast())
        if line.contains(",") {
            let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let tag = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            return FirmwareVersion(grbl: String(parts[0].dropFirst(4)), family: tag.first ?? "",
                                   familyVersion: tag.count > 1 ? tag[1] : "")
        }
        var version = FirmwareVersion()
        for part in line.split(separator: " ") {
            let (key, value) = RealTimeStatus.splitOnce(String(part), ":")
            switch key {
            case "grbl": version.grbl = value
            case "PCB": version.pcb = value
            case "VFD": version.vfd = value
            case "YMD": version.ymd = value
            default:
                if version.family.isEmpty, (2...3).contains(key.count), key.allSatisfy(\.isUppercase) {
                    version.family = key
                    version.familyVersion = value
                }
            }
        }
        return version
    }
}

extension MillConnection {
    /// `FirmwareManager::GetFirmwareVersion`: sends `$I`, reads the info line, discards the `ok`.
    public func firmwareVersion() throws -> FirmwareVersion? {
        try verifyConnected()
        return try lock.withLock {
            try serial.lock.withLock {
                try serial.writeLine("$I", waitMilliseconds: 300)
                // Skip any status reports that arrive in between.
                var line = serial.readLine()
                while let current = line, current.hasPrefix("<") { line = serial.readLine() }
                guard let response = line else { throw MillError(.eStopPushed) }
                serial.flushReads()
                return FirmwareVersion.parse(response)
            }
        }
    }
}
