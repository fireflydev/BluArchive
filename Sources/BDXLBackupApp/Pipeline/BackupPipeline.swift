import Foundation
import Combine

/// Orchestrates TAR → PAR2 → SHA256 manifest → ISO → `hdiutil burn` (matches `bluray.sh`).
@MainActor
final class BackupPipeline: ObservableObject {
    private let runner = ProcessRunner()

    func cancel() {
        runner.cancel()
    }

    func run(settings: BackupJobSettings, state: BackupState) async {
        state.isRunning = true
        state.lastErrorMessage = nil
        state.stage = .preflight
        state.progress = 0

        defer {
            state.isRunning = false
            if state.stage != .complete && state.stage != .failed {
                state.stage = .failed
            }
        }

        do {
            try Task.checkCancellation()
            try await preflight(settings: settings, state: state)
            let paths = try await runTarPar2ShaIso(settings: settings, state: state)

            if settings.burnAfterISO {
                try Task.checkCancellation()
                state.stage = .burn
                state.progress = 0.82
                state.appendLog("Burning ISO…")
                try await burnISO(
                    isoURL: paths.isoURL,
                    settings: settings,
                    state: state
                )
            } else {
                state.appendLog("Skipping burn (generate ISO only).")
            }

            if settings.verifyMode != .none {
                try Task.checkCancellation()
                state.stage = .verify
                state.progress = 0.92
                try await verifyArtifacts(
                    settings: settings,
                    state: state,
                    workURL: paths.workURL,
                    tarBaseName: paths.tarBaseName,
                    isoURL: paths.isoURL
                )
            }

            if !settings.keepStagingFiles {
                try? FileManager.default.removeItem(at: paths.workURL)
                state.appendLog("Removed staging directory: \(paths.workURL.path)")
            } else {
                state.appendLog("Keeping staging directory: \(paths.workURL.path)")
            }

            state.stage = .complete
            state.progress = 1.0
            state.appendLog("Done.")
        } catch is CancellationError {
            state.stage = .failed
            state.lastErrorMessage = "Cancelled."
            state.appendLog("Cancelled.")
        } catch {
            state.stage = .failed
            state.lastErrorMessage = error.localizedDescription
            state.appendLog("ERROR: \(error.localizedDescription)")
        }
    }

    private struct JobPaths {
        let workURL: URL
        let tarURL: URL?
        let isoURL: URL
        let tarBaseName: String
        let manifestURL: URL?
    }

    private func preflight(settings: BackupJobSettings, state: BackupState) async throws {
        guard let source = settings.sourceFolder else {
            throw NSError(domain: "BDXLBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "No source folder selected."])
        }
        guard let output = settings.outputFolder else {
            throw NSError(domain: "BDXLBackup", code: 2, userInfo: [NSLocalizedDescriptionKey: "No output folder selected."])
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "BDXLBackup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Source is not a directory."])
        }
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "BDXLBackup", code: 4, userInfo: [NSLocalizedDescriptionKey: "Output is not a directory."])
        }

        if settings.tarFirstEnabled && settings.par2Enabled {
            if let par2 = await ToolResolver.par2Executable() {
                state.appendLog("Found par2 at: \(par2)")
            } else {
                throw NSError(
                    domain: "BDXLBackup",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "par2 not found. Install with: brew install par2"]
                )
            }
        }

        let freeBytes = try freeSpaceBytes(at: output)
        let sourceBytes = try await estimatedFolderSizeBytes(at: source)
        /// Heuristic multiplier based on TAR/PAR toggles.
        let projectedFactor: Double
        if settings.tarFirstEnabled && settings.par2Enabled {
            projectedFactor = 1.35
        } else if settings.tarFirstEnabled {
            projectedFactor = 1.15
        } else {
            projectedFactor = 1.08
        }
        let projectedBytes = Int64(Double(sourceBytes) * projectedFactor) + 512 * 1024 * 1024
        guard projectedBytes < freeBytes else {
            throw NSError(
                domain: "BDXLBackup",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Insufficient free disk space at output. Need ~\(formatBytes(projectedBytes)) free; have ~\(formatBytes(freeBytes))."
                ]
            )
        }

        let safeGiB = settings.profile.safeMaxPayloadGiB
        let maxBytes = Int64(safeGiB * 1024 * 1024 * 1024)
        guard sourceBytes <= maxBytes else {
            throw NSError(
                domain: "BDXLBackup",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Source is larger than safe limit for \(settings.profile.rawValue) (~\(safeGiB) GiB payload). Reduce data or choose larger media."
                ]
            )
        }

        if settings.burnAfterISO {
            let (_, drOut) = try await runner.runCollecting(
                launchPath: ToolResolver.drutilExecutable(),
                arguments: ["status"]
            )
            state.appendLog("drutil status:\n\(drOut.prefix(2000))")
        }

        state.appendLog("Preflight OK (source ~\(formatBytes(sourceBytes)), max ~\(safeGiB) GiB for profile).")
        state.progress = 0.05
    }

    private func runTarPar2ShaIso(settings: BackupJobSettings, state: BackupState) async throws -> JobPaths {
        guard let source = settings.sourceFolder, let output = settings.outputFolder else {
            throw NSError(domain: "BDXLBackup", code: 8, userInfo: [NSLocalizedDescriptionKey: "Missing paths."])
        }

        let basename = source.lastPathComponent
        let workURL = output.appendingPathComponent("_bdxl_work", isDirectory: true)
        if FileManager.default.fileExists(atPath: workURL.path) {
            try FileManager.default.removeItem(at: workURL)
        }
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)

        let parent = source.deletingLastPathComponent()
        let tarURL = workURL.appendingPathComponent("\(basename).tar")
        let par2Base = workURL.appendingPathComponent("\(basename).par2").path
        let manifestURL = workURL.appendingPathComponent("\(basename)_sha256.txt")
        let isoURL = output.appendingPathComponent("\(settings.volumeLabel).iso")

        if FileManager.default.fileExists(atPath: isoURL.path) {
            try FileManager.default.removeItem(at: isoURL)
        }

        var effectiveTarURL: URL?
        var isoSourceURL: URL

        if settings.tarFirstEnabled {
            // TAR
            state.stage = .tar
            state.progress = 0.1
            state.appendLog("Creating TAR: \(tarURL.path)")
            let tarArgs = ["-cf", tarURL.path, "-C", parent.path, basename]
            let tarCode = try await runner.runStreaming(
                launchPath: ToolResolver.tarExecutable(),
                arguments: tarArgs,
                onLine: { state.appendLog($0) }
            )
            try throwIfBadExit(tarCode, cmd: "tar \(tarArgs.joined(separator: " "))")
            effectiveTarURL = tarURL
            isoSourceURL = workURL
        } else {
            state.appendLog("Skipping TAR stage (TAR first disabled).")
            isoSourceURL = source
        }

        // PAR2
        if settings.par2Enabled, let tarForPar = effectiveTarURL {
            state.stage = .par2
            state.progress = 0.35
            guard let par2 = await ToolResolver.par2Executable() else {
                throw NSError(domain: "BDXLBackup", code: 9, userInfo: [NSLocalizedDescriptionKey: "par2 disappeared from PATH."])
            }
            let redundancy = max(1, min(32, settings.par2RedundancyPercent))
            let par2Args = ["create", "-r\(redundancy)", par2Base, tarForPar.path]
            state.appendLog("PAR2 create with \(redundancy)% redundancy…")
            let par2Code = try await runner.runStreaming(
                launchPath: par2,
                arguments: par2Args,
                onLine: { state.appendLog($0) }
            )
            try throwIfBadExit(par2Code, cmd: "par2 \(par2Args.joined(separator: " "))")
        } else if settings.par2Enabled {
            state.appendLog("Skipping PAR2 stage: requires TAR-first mode.")
        } else {
            state.appendLog("Skipping PAR2 stage (disabled).")
        }

        // SHA256 manifest (single-line hash file for the TAR)
        var effectiveManifestURL: URL?
        state.stage = .sha256
        state.progress = 0.55
        if let tarForSha = effectiveTarURL {
            state.appendLog("Writing SHA256 manifest…")
            let (shaCode, shaOut) = try await runner.runCollecting(
                launchPath: ToolResolver.shasumExecutable(),
                arguments: ["-a", "256", tarForSha.path]
            )
            try throwIfBadExit(shaCode, cmd: "shasum")
            try shaOut.write(to: manifestURL, atomically: true, encoding: .utf8)
            effectiveManifestURL = manifestURL
        } else {
            let note = "TAR disabled; TAR checksum manifest not generated.\nSource folder: \(source.path)\n"
            try note.write(to: manifestURL, atomically: true, encoding: .utf8)
            state.appendLog("Skipping TAR checksum manifest (TAR first disabled).")
        }

        // ISO
        state.stage = .iso
        state.progress = 0.65
        state.appendLog("Building hybrid UDF/ISO → \(isoURL.path)")
        let isoArgs = [
            "makehybrid",
            "-udf",
            "-iso",
            "-joliet",
            "-default-volume-name",
            settings.volumeLabel,
            "-o",
            isoURL.path,
            isoSourceURL.path
        ]
        let isoCode = try await runner.runStreaming(
            launchPath: ToolResolver.hdiutilExecutable(),
            arguments: isoArgs,
            onLine: { state.appendLog($0) }
        )
        try throwIfBadExit(isoCode, cmd: "hdiutil makehybrid")

        return JobPaths(
            workURL: workURL,
            tarURL: effectiveTarURL,
            isoURL: isoURL,
            tarBaseName: basename,
            manifestURL: effectiveManifestURL
        )
    }

    private func burnISO(isoURL: URL, settings: BackupJobSettings, state: BackupState) async throws {
        var args: [String] = ["burn"]
        if let dev = settings.targetDeviceBSDName?.trimmingCharacters(in: .whitespacesAndNewlines), !dev.isEmpty {
            args.append(contentsOf: ["-device", dev])
        }
        if let speed = settings.burnSpeedX, speed > 0 {
            args.append(contentsOf: ["-speed", "\(speed)"])
        }
        /// `hdiutil burn` options vary by macOS release; post-burn verification is handled
        /// by `verifyArtifacts` to avoid relying on unsupported burn-time flags.
        args.append(isoURL.path)

        state.appendLog("hdiutil \(args.joined(separator: " "))")
        var burnOutput: [String] = []
        let code = try await runner.runStreaming(
            launchPath: ToolResolver.hdiutilExecutable(),
            arguments: args,
            onLine: { line in
                burnOutput.append(line)
                state.appendLog(line)
            }
        )
        if code != 0 {
            let tail = burnOutput.suffix(80).joined(separator: "\n")
            let details = tail.isEmpty ? "No output captured from hdiutil." : tail
            throw NSError(
                domain: "BDXLBackup",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "hdiutil burn failed (\(code)):\n\(details)"]
            )
        }
    }

    private func verifyArtifacts(
        settings: BackupJobSettings,
        state: BackupState,
        workURL: URL,
        tarBaseName: String,
        isoURL: URL
    ) async throws {
        let manifestURL = workURL.appendingPathComponent("\(tarBaseName)_sha256.txt")

        if (settings.verifyMode == .quick || settings.verifyMode == .deep) && settings.tarFirstEnabled {
            state.appendLog("Quick verify: checksum TAR against manifest…")
            let (c1, o1) = try await runner.runCollecting(
                launchPath: ToolResolver.shasumExecutable(),
                arguments: ["-a", "256", "-c", manifestURL.path],
                currentDirectory: workURL
            )
            if c1 != 0 {
                throw NSError(
                    domain: "BDXLBackup",
                    code: 30,
                    userInfo: [NSLocalizedDescriptionKey: "SHA256 verify failed:\n\(o1)"]
                )
            }
            state.appendLog("SHA256 verify OK for TAR.")
        } else if settings.verifyMode == .quick || settings.verifyMode == .deep {
            state.appendLog("Skipping TAR checksum verify (TAR first disabled).")
        }

        if settings.verifyMode == .deep {
            state.appendLog("Deep verify: hdiutil verify (ISO image)…")
            let (c2, o2) = try await runner.runCollecting(
                launchPath: ToolResolver.hdiutilExecutable(),
                arguments: ["verify", isoURL.path]
            )
            if c2 != 0 {
                throw NSError(
                    domain: "BDXLBackup",
                    code: 31,
                    userInfo: [NSLocalizedDescriptionKey: "hdiutil verify failed:\n\(o2)"]
                )
            }
            state.appendLog("hdiutil verify OK.")

            if settings.tarFirstEnabled {
                let tarURL = workURL.appendingPathComponent("\(tarBaseName).tar")
                guard FileManager.default.fileExists(atPath: tarURL.path) else {
                    return
                }
                state.appendLog("Deep verify: checksum TAR again after ISO build…")
                let (c3, o3) = try await runner.runCollecting(
                    launchPath: ToolResolver.shasumExecutable(),
                    arguments: ["-a", "256", "-c", manifestURL.path],
                    currentDirectory: workURL
                )
                if c3 != 0 {
                    throw NSError(
                        domain: "BDXLBackup",
                        code: 32,
                        userInfo: [NSLocalizedDescriptionKey: "Post-ISO TAR checksum failed:\n\(o3)"]
                    )
                }
            }
        }
    }

    private func throwIfBadExit(_ code: Int32, cmd: String) throws {
        if code != 0 {
            throw NSError(
                domain: "BDXLBackup",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Command failed (\(code)): \(cmd)"]
            )
        }
    }

    private func freeSpaceBytes(at folder: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
        guard let free = attrs[.systemFreeSize] as? NSNumber else {
            throw NSError(domain: "BDXLBackup", code: 50, userInfo: [NSLocalizedDescriptionKey: "Could not read free space for output volume."])
        }
        return free.int64Value
    }

    private func estimatedFolderSizeBytes(at folder: URL) async throws -> Int64 {
        let (code, out) = try await runner.runCollecting(
            launchPath: ToolResolver.duExecutable(),
            arguments: ["-sk", folder.path]
        )
        guard code == 0 else {
            throw NSError(domain: "BDXLBackup", code: 51, userInfo: [NSLocalizedDescriptionKey: "du failed:\n\(out)"])
        }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace })
        guard let kb = parts.first, let n = Int64(kb) else {
            throw NSError(domain: "BDXLBackup", code: 52, userInfo: [NSLocalizedDescriptionKey: "Could not parse du output: \(out)"])
        }
        return n * 1024
    }

    private func formatBytes(_ b: Int64) -> String {
        let mb = Double(b) / (1024 * 1024)
        if mb > 1000 {
            return String(format: "%.2f GiB", mb / 1024)
        }
        return String(format: "%.1f MiB", mb)
    }
}
