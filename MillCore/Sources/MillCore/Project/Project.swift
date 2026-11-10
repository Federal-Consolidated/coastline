import Foundation

/// One step ("operation") of a guided job. Port of `Operation` (`src/Files/operation.cpp`).
public struct Step: Equatable, Sendable, Identifiable {
    public var id = UUID()
    /// The manifest file this step came from (`manifest.yml` or a sub-manifest path).
    public var manifest: String
    /// Which `manifest_file:` reference spliced this step in (nil for steps written inline).
    /// Lets the writer reproduce the references exactly, even for back-to-back reuse.
    public var spliceIndex: Int?
    public var title = ""
    /// `step_text`: plain text shown when there is no markdown.
    public var prompt = ""
    /// `step_markdown`.
    public var markdown = ""
    /// `step_image`: entry path of the image, empty when none.
    public var imagePath = ""
    /// `step_gcode`: entry path of the G-code file, empty when none.
    public var gcodePath = ""
    public var pause = false
    public var reset = false
    public var timeout: UInt = 0
    /// `unskippable` (raw string; the original compares it to `"true"`). Set to "true" by `popup_text`.
    public var unskippable = ""
    public var popupText = ""
    public var popupTitle = ""
    public var popupWaitTime = 0
    /// `popup_yes_step` / `popup_no_step` / `step_goto`: absolute index or relative `+n`/`-n`.
    public var popupYesStep = ""
    public var popupNoStep = ""
    public var goTo = ""
    /// `if: name==N` — parsed but unused by the original app; kept for round-tripping.
    public var conditionName: String?
    public var conditionValue = 0

    public init(manifest: String) {
        self.manifest = manifest
    }

    /// A blank step as created by the editor (`Operation(const std::string manifest)`).
    public static func placeholder(manifest: String) -> Step {
        var step = Step(manifest: manifest)
        step.title = "Step Name"
        step.markdown = "\nStep Text"
        step.prompt = "Please update the software that runs this job."
        return step
    }

    public var hasGCode: Bool { !gcodePath.isEmpty }
    public var isUnskippable: Bool { unskippable == "true" }
    public var hasPopup: Bool { !popupText.isEmpty }

    public static func == (lhs: Step, rhs: Step) -> Bool {
        lhs.manifest == rhs.manifest && lhs.title == rhs.title && lhs.prompt == rhs.prompt
            && lhs.markdown == rhs.markdown && lhs.imagePath == rhs.imagePath && lhs.gcodePath == rhs.gcodePath
            && lhs.pause == rhs.pause && lhs.reset == rhs.reset && lhs.timeout == rhs.timeout
            && lhs.unskippable == rhs.unskippable && lhs.popupText == rhs.popupText
            && lhs.popupTitle == rhs.popupTitle && lhs.popupWaitTime == rhs.popupWaitTime
            && lhs.popupYesStep == rhs.popupYesStep && lhs.popupNoStep == rhs.popupNoStep
            && lhs.goTo == rhs.goTo && lhs.conditionName == rhs.conditionName
            && lhs.conditionValue == rhs.conditionValue
    }
}

/// A work-coordinate check from `wcs_value_check: G54 X.. Y.. Z..`.
public struct WCSCheck: Equatable, Sendable {
    /// 54...59, or -1 when missing.
    public var wcs: Int
    public var x: Double
    public var y: Double
    public var z: Double
}

/// A guided job. Port of `Job` (`src/Files/job.cpp`).
public struct Job: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var title = ""
    public var prompt = ""
    public var steps: [Step] = []
    public var guideFiles: [String] = []
    public var modelFiles: [String] = []
    /// `min_fw_version`, a YYYYMMDD date string.
    public var minFirmwareVersion = ""
    /// `min_crwrite_version`, dotted.
    public var minSenderVersion = ""
    public var allowWCSClearPrompt = true
    public var wcsChecks: [WCSCheck] = []
    public var wcsCheckFailedMessage = ""

    public init(title: String = "", prompt: String = "") {
        self.title = title
        self.prompt = prompt
    }

    /// True when any step comes from a sub-manifest (the original disables editing then).
    public var usesSubmanifests: Bool { steps.contains { $0.manifest != "manifest.yml" } }

    public static func == (lhs: Job, rhs: Job) -> Bool {
        lhs.title == rhs.title && lhs.prompt == rhs.prompt && lhs.steps == rhs.steps
            && lhs.guideFiles == rhs.guideFiles && lhs.modelFiles == rhs.modelFiles
            && lhs.minFirmwareVersion == rhs.minFirmwareVersion && lhs.minSenderVersion == rhs.minSenderVersion
            && lhs.allowWCSClearPrompt == rhs.allowWCSClearPrompt && lhs.wcsChecks == rhs.wcsChecks
            && lhs.wcsCheckFailedMessage == rhs.wcsCheckFailedMessage
    }
}
