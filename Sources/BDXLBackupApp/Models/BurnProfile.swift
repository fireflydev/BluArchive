import Foundation

/// Profile for Blu-ray / BDXL nominal sizes with conservative usable ceilings (GiB).
enum BurnProfile: String, CaseIterable, Identifiable, Sendable {
    case bdR25 = "BD-R 25 GB"
    case bdRDL50 = "BD-R DL 50 GB"
    case bdxlTL100 = "BDXL TL 100 GB"
    case bdxlQL128 = "BDXL QL 128 GB"

    var id: String { rawValue }

    /// Marketing label capacity (decimal GB).
    var nominalCapacityGB: Int {
        switch self {
        case .bdR25: return 25
        case .bdRDL50: return 50
        case .bdxlTL100: return 100
        case .bdxlQL128: return 128
        }
    }

    /// Safe maximum payload (tar + par2 + manifest + ISO overhead), in GiB (binary).
    /// Mirrors bluray.sh `MAX_GIB=115` for 128GB-class media; smaller discs use proportional headroom.
    var safeMaxPayloadGiB: Double {
        switch self {
        case .bdR25: return 22.5
        case .bdRDL50: return 46.0
        case .bdxlTL100: return 92.0
        case .bdxlQL128: return 115.0
        }
    }

    /// Best-effort mapping from `drutil` / `diskutil` media descriptions to app profiles.
    static func infer(from mediaText: String) -> BurnProfile? {
        let upper = mediaText.uppercased()
        guard upper.contains("BD") || upper.contains("BLU") else {
            return nil
        }

        // Prefer most specific matches first.
        if upper.contains("BDXL"), (upper.contains("QL") || upper.contains("4L") || upper.contains("128")) {
            return .bdxlQL128
        }
        if upper.contains("BDXL")
            || upper.contains("TRIPLE")
            || upper.contains("TL")
            || upper.contains("100GB")
            || upper.contains("100 GB") {
            return .bdxlTL100
        }
        if upper.contains("DL")
            || upper.contains("DOUBLE")
            || upper.contains("DUAL")
            || upper.contains("50GB")
            || upper.contains("50 GB") {
            return .bdRDL50
        }
        if upper.contains("BD-R")
            || upper.contains("BDRE")
            || upper.contains("BD-RE")
            || upper.contains("BLU-RAY")
            || upper.contains("BLURAY") {
            return .bdR25
        }
        return nil
    }
}

enum VerifyMode: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case quick = "Quick (checksum manifest)"
    case deep = "Deep (hdiutil verify + checksums)"

    var id: String { rawValue }
}

enum BackupStage: String, CaseIterable, Identifiable, Sendable, Hashable {
    case idle = "Idle"
    case preflight = "Preflight"
    case tar = "Create TAR"
    case par2 = "PAR2 redundancy"
    case sha256 = "SHA256 manifest"
    case iso = "Build ISO"
    case burn = "Burn disc"
    case verify = "Verify"
    case complete = "Complete"
    case failed = "Failed"

    var id: String { rawValue }
}

struct BackupJobSettings: Sendable {
    var sourceFolder: URL?
    var outputFolder: URL?
    var volumeLabel: String = "BDXL_ARCHIVE"
    /// Reliability-first path that mirrors archival workflow.
    var tarFirstEnabled: Bool = true
    /// Optional parity recovery files.
    var par2Enabled: Bool = true
    var profile: BurnProfile = .bdxlQL128
    var par2RedundancyPercent: Int = 12
    var burnAfterISO: Bool = true
    /// nil = drive/default automatic speed
    var burnSpeedX: Int? = 1
    var targetDeviceBSDName: String?
    /// When true, keeps `_bdxl_work` after success (for debugging).
    var keepStagingFiles: Bool = false
    var verifyMode: VerifyMode = .quick
}
