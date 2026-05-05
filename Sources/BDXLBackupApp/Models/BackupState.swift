import Foundation
import Combine

/// User-facing backup session state (mirrors pipeline progress for UI).
@MainActor
final class BackupState: ObservableObject {
    @Published var stage: BackupStage = .idle
    @Published var progress: Double = 0
    @Published var logLines: [String] = []
    @Published var isRunning: Bool = false
    @Published var lastErrorMessage: String?

    func appendLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logLines.append("[\(stamp)] \(line)")
    }

    func clearLog() {
        logLines.removeAll()
    }

    func resetForNewRun() {
        stage = .idle
        progress = 0
        lastErrorMessage = nil
        isRunning = false
        clearLog()
    }

    func exportDiagnosticsText(job: BackupJobSettings) -> String {
        var body = "BluArchive — diagnostics export\n\n"
        body += "Source: \(job.sourceFolder?.path ?? "(none)")\n"
        body += "Output: \(job.outputFolder?.path ?? "(none)")\n"
        body += "Volume label: \(job.volumeLabel)\n"
        body += "Profile: \(job.profile.rawValue) (safe max ~\(job.profile.safeMaxPayloadGiB) GiB)\n"
        body += "TAR first: \(job.tarFirstEnabled)\n"
        body += "PAR2 enabled: \(job.par2Enabled)\n"
        body += "PAR2 redundancy: \(job.par2RedundancyPercent)%\n"
        body += "Burn: \(job.burnAfterISO)\n"
        if let speed = job.burnSpeedX {
            body += "Burn speed: \(speed)x\n"
        } else {
            body += "Burn speed: Auto (drive default)\n"
        }
        body += "Device: \(job.targetDeviceBSDName ?? "system default")\n"
        body += "Verify: \(job.verifyMode.rawValue)\n"
        body += "Keep staging: \(job.keepStagingFiles)\n\n--- Log ---\n"
        body += logLines.joined(separator: "\n")
        return body
    }
}
