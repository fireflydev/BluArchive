import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var state = BackupState()
    @StateObject private var pipeline = BackupPipeline()
    @State private var settings = BackupJobSettings()

    @State private var drives: [OpticalDriveInfo] = []
    @State private var selectedDriveId: String = "default"
    @State private var manualBSDName: String = ""
    @State private var runTask: Task<Void, Never>?
    @State private var showHelp = false
    @State private var showOutputArtifactsInfo = false
    @State private var showBurnSpeedInfo = false
    @State private var availableBurnSpeeds: [Int] = [1, 2, 4, 6, 8, 12, 16]
    @State private var detectedMediaLabel: String?

    var body: some View {
        GeometryReader { proxy in
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    brandTitle
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal)
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                    Form {
                        Section("Source & staging") {
                            HStack(spacing: 12) {
                                Button("Open Tray") {
                                    Task { await setTray(open: true) }
                                }
                                Button("Close Tray") {
                                    Task { await setTray(open: false) }
                                }
                            }
                                HStack {
                                    Text(settings.sourceFolder?.path ?? "No folder selected")
                                        .lineLimit(2)
                                        .foregroundStyle(settings.sourceFolder == nil ? .secondary : .primary)
                                    Spacer()
                                    Button("Choose…") { chooseSource() }
                                }
                                HStack(alignment: .center, spacing: 6) {
                                    Text("Staging: \(currentStagingFolderPath)")
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                    Button {
                                        showOutputArtifactsInfo.toggle()
                                    } label: {
                                        Image(systemName: "info.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Why you pick a staging folder (not /tmp)")
                                    .popover(isPresented: $showOutputArtifactsInfo, arrowEdge: .leading) {
                                        outputArtifactsExplanation
                                            .frame(maxWidth: 380)
                                            .padding()
                                    }
                                    Spacer()
                                    Button("Choose…") { chooseOutput() }
                                }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Volume label")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Volume label", text: $settings.volumeLabel)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.black.opacity(0.18))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                    )
                            }
                            }

                            Section("Archive preparation") {
                                Toggle("TAR first (recommended for reliability)", isOn: $settings.tarFirstEnabled)
                                Text("Using TAR first improves reliability by packaging folder metadata consistently before ISO creation.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Toggle("Enable PAR2 redundancy", isOn: $settings.par2Enabled)
                                Stepper(
                                    "PAR2 redundancy: \(settings.par2RedundancyPercent)%",
                                    value: $settings.par2RedundancyPercent,
                                    in: 5...30,
                                    step: 1
                                )
                                .disabled(!settings.par2Enabled)
                            }

                            Section("Media") {
                                Picker("Media profile", selection: $settings.profile) {
                                    ForEach(BurnProfile.allCases) { p in
                                        Text("\(p.rawValue) (~\(String(format: "%.1f", p.safeMaxPayloadGiB)) GiB safe)")
                                            .tag(p)
                                    }
                                }
                                if let label = detectedMediaLabel {
                                    Text("Detected disc: \(label)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("Usable payload limit is approximate; leave margin for filesystem overhead.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Section("Burn") {
                                Toggle("Burn after building ISO", isOn: $settings.burnAfterISO)
                                HStack(alignment: .center, spacing: 6) {
                                    Text("Burn speed")
                                    Button {
                                        showBurnSpeedInfo.toggle()
                                    } label: {
                                        Image(systemName: "info.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Burn speed reliability guidance")
                                    .popover(isPresented: $showBurnSpeedInfo, arrowEdge: .leading) {
                                        burnSpeedExplanation
                                            .frame(maxWidth: 360)
                                            .padding()
                                    }
                                    Spacer()
                                    Picker("", selection: $settings.burnSpeedX) {
                                        Text("Auto (drive default)").tag(Int?.none)
                                        ForEach(availableBurnSpeeds, id: \.self) { speed in
                                            Text("\(speed)x").tag(Optional(speed))
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }
                                .disabled(!settings.burnAfterISO)
                                Picker("Target drive", selection: $selectedDriveId) {
                                    ForEach(drives) { d in
                                        Text(d.title).tag(d.id)
                                    }
                                }
                                .disabled(!settings.burnAfterISO)
                                TextField("Manual BSD device (optional), e.g. disk4", text: $manualBSDName)
                                    .disabled(!settings.burnAfterISO)
                                if let hint = selectedDrive?.bsdName {
                                    Text("Detected BSD: \(hint)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button("Refresh drives") {
                                    Task { await refreshDrives() }
                                }
                                .disabled(!settings.burnAfterISO)
                            }

                        Section("Verification & staging") {
                                Picker("Verify", selection: $settings.verifyMode) {
                                    ForEach(VerifyMode.allCases) { v in
                                        Text(v.rawValue).tag(v)
                                    }
                                }
                            Toggle("Keep BluArchive staging folder (_bdxl_work)", isOn: $settings.keepStagingFiles)
                            }

                            Section("Actions") {
                                stagesTimeline
                                ProgressView(value: state.progress)
                                HStack {
                                    Button(state.isRunning ? "Running…" : "Run backup") {
                                        startRun()
                                    }
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(state.isRunning || settings.sourceFolder == nil || settings.outputFolder == nil)

                                    Button("Cancel") {
                                        cancelRun()
                                    }
                                    .disabled(!state.isRunning)

                                    Button("Export diagnostics…") {
                                        exportDiagnostics()
                                    }
                                    .disabled(state.logLines.isEmpty)

                                    Spacer()
                                    Button("Help") { showHelp = true }
                                }

                                if let err = state.lastErrorMessage {
                                    Text(err)
                                        .foregroundStyle(.red)
                                        .font(.callout)
                                }
                            }
                        }
                    .groupedFormIfAvailable()
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .frame(
                    minWidth: max(520, proxy.size.width * 0.78),
                    idealWidth: proxy.size.width * 0.8,
                    maxWidth: proxy.size.width * 0.84
                )

                LogView(lines: $state.logLines)
                    .padding()
                    .frame(maxHeight: .infinity)
                    .frame(
                        minWidth: max(180, proxy.size.width * 0.16),
                        idealWidth: proxy.size.width * 0.2,
                        maxWidth: proxy.size.width * 0.24
                    )
            }
            .frame(maxHeight: .infinity)
        }
        .task {
            await refreshDrives()
            if settings.outputFolder == nil {
                settings.outputFolder = defaultStagingFolderURL
            }
            if let dir = settings.outputFolder {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        .onChange(of: selectedDriveId) { _ in
            syncBurnTargetFromUI()
            Task {
                await refreshBurnSpeeds()
                await refreshDetectedMedia()
            }
        }
        .onChange(of: manualBSDName) { _ in
            syncBurnTargetFromUI()
            Task {
                await refreshBurnSpeeds()
                await refreshDetectedMedia()
            }
        }
        .onChange(of: settings.burnAfterISO) { _ in
            syncBurnTargetFromUI()
            Task {
                await refreshBurnSpeeds()
                await refreshDetectedMedia()
            }
        }
        .sheet(isPresented: $showHelp) {
            helpSheet
        }
    }

    private var selectedDrive: OpticalDriveInfo? {
        drives.first { $0.id == selectedDriveId }
    }

    private var brandTitle: some View {
        HStack(spacing: 0) {
            Text("Blu")
                .foregroundStyle(Color(red: 0.10, green: 0.50, blue: 1.00))
            Text("Archive")
                .foregroundStyle(Color(red: 0.00, green: 0.72, blue: 0.95))
        }
        .font(.system(size: 44, weight: .heavy, design: .default))
        .trackingIfAvailable(0.2)
        .lineLimit(1)
    }

    private var defaultStagingFolderURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("BluArchive Staging", isDirectory: true)
    }

    private var currentStagingFolderPath: String {
        if let path = settings.outputFolder?.path {
            return path
        }
        return defaultStagingFolderURL?.path ?? "(default unavailable)"
    }

    private var stagesTimeline: some View {
        HStack(spacing: 4) {
            ForEach(
                [BackupStage.preflight, .tar, .par2, .sha256, .iso, .burn, .verify, .complete]
                    .filter { stage in
                        if !settings.tarFirstEnabled && stage == .tar { return false }
                        if !settings.par2Enabled && stage == .par2 { return false }
                        if !settings.burnAfterISO && stage == .burn { return false }
                        if settings.verifyMode == .none && stage == .verify { return false }
                        return true
                    }
            ) { stage in
                let active = state.stage == stage
                Text(stage.rawValue)
                    .font(.caption2)
                    .padding(4)
                    .background(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private var outputArtifactsExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Staging folder")
                .font(.headline)
            Text(
                """
                BluArchive writes large working files and your final image here:

                • _bdxl_work/ — staging folder (TAR, PAR2 pieces, checksum manifest when those options are on)
                • Your volume name + .iso — the hybrid UDF/ISO you burn

                Why not /tmp? macOS can wipe or pressure-clean temporary storage. \
                Archive jobs can run for hours and need multi‑tens-of-GB free space, \
                so a staging folder you control is safer and easier to find later.
                """
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var burnSpeedExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Burn speed reliability")
                .font(.headline)
            Text(
                """
                For archival reliability, use the lowest stable speed your drive and media support.

                Typical guidance:
                • 1x–4x: safest for long-term archives
                • 6x+: faster but can increase write variability on some media
                • Auto: lets the drive choose

                BluArchive detects available write speeds from the connected optical drive and media.
                """
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var helpSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup")
                .font(.title2.bold())
            Text("Install PAR2: `brew install par2`")
            Text("BluArchive wraps tar, par2, shasum, and hdiutil — same flow as bluray.sh.")
            Text("Always stay under the safe GiB limit for your disc. BDXL QL uses ~115 GiB payload budget.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { showHelp = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }

    private func syncBurnTargetFromUI() {
        guard settings.burnAfterISO else {
            settings.targetDeviceBSDName = nil
            return
        }
        let manual = manualBSDName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            if manual.hasPrefix("/dev/") {
                settings.targetDeviceBSDName = manual
            } else {
                settings.targetDeviceBSDName = "/dev/\(manual)"
            }
            return
        }
        if let d = selectedDrive, let bsd = d.bsdName, !bsd.isEmpty {
            let node = bsd.replacingOccurrences(of: "/dev/", with: "")
            settings.targetDeviceBSDName = "/dev/\(node)"
        } else {
            settings.targetDeviceBSDName = nil
        }
    }

    private func chooseSource() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Choose folder"
        if p.runModal() == .OK, let url = p.url {
            settings.sourceFolder = url
        }
    }

    private func chooseOutput() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Staging folder"
        if p.runModal() == .OK, let url = p.url {
            settings.outputFolder = url
        }
    }

    private func refreshDrives() async {
        let list = await DriveDiscovery.discoverDrives()
        drives = list
        if !list.contains(where: { $0.id == selectedDriveId }) {
            selectedDriveId = list.first?.id ?? "default"
        }
        syncBurnTargetFromUI()
        await refreshBurnSpeeds()
        await refreshDetectedMedia()
    }

    private func refreshBurnSpeeds() async {
        let speeds = await DriveDiscovery.discoverWriteSpeeds(deviceBSDName: settings.targetDeviceBSDName)
        availableBurnSpeeds = speeds
        if let selected = settings.burnSpeedX, !speeds.contains(selected) {
            settings.burnSpeedX = speeds.first
        }
    }

    private func refreshDetectedMedia() async {
        guard settings.burnAfterISO else {
            detectedMediaLabel = nil
            return
        }

        let detection = await DriveDiscovery.detectInsertedMedia(deviceBSDName: settings.targetDeviceBSDName)
        detectedMediaLabel = detection.label
        if let profile = detection.profile {
            settings.profile = profile
        }
    }

    private func setTray(open: Bool) async {
        let verb = open ? "open" : "close"
        let actionTitle = open ? "open" : "close"
        state.appendLog("Attempting to \(actionTitle) optical tray…")
        let runner = ProcessRunner()

        if open,
           let dev = settings.targetDeviceBSDName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dev.isEmpty {
            do {
                let (code, out) = try await runner.runCollecting(
                    launchPath: ToolResolver.hdiutilExecutable(),
                    arguments: ["eject", dev]
                )
                if code == 0 {
                    state.appendLog("Tray/eject command sent for \(dev).")
                    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        state.appendLog(trimmed)
                    }
                    return
                }
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    state.appendLog("hdiutil eject returned \(code): \(trimmed)")
                }
            } catch {
                state.appendLog("Device eject attempt failed: \(error.localizedDescription)")
            }
        }

        do {
            let (code, out) = try await runner.runCollecting(
                launchPath: ToolResolver.drutilExecutable(),
                arguments: ["tray", verb]
            )
            if code == 0 {
                state.appendLog("Tray \(verb) command sent.")
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    state.appendLog(trimmed)
                }
            } else {
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = trimmed.isEmpty ? "Exit code \(code)." : trimmed
                let prefix = open ? "Open" : "Close"
                state.lastErrorMessage = "\(prefix) tray failed: \(message)"
                state.appendLog("\(prefix) tray failed: \(message)")
            }
        } catch {
            let prefix = open ? "Open" : "Close"
            state.lastErrorMessage = "\(prefix) tray failed: \(error.localizedDescription)"
            state.appendLog("\(prefix) tray failed: \(error.localizedDescription)")
        }
    }

    private func startRun() {
        syncBurnTargetFromUI()
        state.resetForNewRun()
        state.appendLog("Starting backup…")

        runTask = Task {
            await pipeline.run(settings: settings, state: state)
        }
    }

    private func cancelRun() {
        pipeline.cancel()
        runTask?.cancel()
        state.appendLog("Cancel requested…")
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "BluArchive-diagnostics.txt"
        if panel.runModal() == .OK, let url = panel.url {
            let text = state.exportDiagnosticsText(job: settings)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                state.appendLog("Failed to export: \(error.localizedDescription)")
            }
        }
    }
}

