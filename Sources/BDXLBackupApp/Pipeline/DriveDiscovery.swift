import Foundation

struct OpticalDriveInfo: Identifiable, Hashable, Sendable {
    var id: String
    /// Display label for menus.
    var title: String
    /// Optional BSD disk path for `hdiutil burn -device`, e.g. `/dev/disk4`.
    var bsdName: String?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: OpticalDriveInfo, rhs: OpticalDriveInfo) -> Bool {
        lhs.id == rhs.id
    }
}

struct OpticalMediaDetection: Sendable {
    var profile: BurnProfile?
    var label: String?
}

enum DriveDiscovery {
    /// Lists optical writers using `drutil list` and enriches with `/dev/disk*` when possible.
    static func discoverDrives() async -> [OpticalDriveInfo] {
        let runnercollected = ProcessRunner()
        var drives: [OpticalDriveInfo] = []

        let drPath = ToolResolver.drutilExecutable()
        guard FileManager.default.isExecutableFile(atPath: drPath) else {
            return [OpticalDriveInfo(id: "default", title: "System default burner", bsdName: nil)]
        }

        do {
            let (_, raw) = try await runnercollected.runCollecting(
                launchPath: drPath,
                arguments: ["list"]
            )
            drives.append(contentsOf: parseDrutilList(raw))
        } catch {
            // Fall through with minimal entry
        }

        if drives.isEmpty {
            drives.append(OpticalDriveInfo(id: "default", title: "System default burner", bsdName: nil))
        } else {
            drives.insert(OpticalDriveInfo(id: "default", title: "System default burner", bsdName: nil), at: 0)
        }

        let diskMap = await bsdNamesForOpticalDrives()
        return drives.map { info in
            guard let key = info.title.split(separator: " ").first.map(String.init) else {
                return info
            }
            let bsd = diskMap[key] ?? info.bsdName
            return OpticalDriveInfo(id: info.id, title: info.title, bsdName: bsd)
        }
    }

    /// Parses `drutil list` — format varies by macOS; handles common "Drive N" sections.
    static func parseDrutilList(_ text: String) -> [OpticalDriveInfo] {
        var result: [OpticalDriveInfo] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var currentIndex: String?
        var vendor = ""
        var product = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.lowercased().hasPrefix("drive") {
                // e.g. "Drive 1"
                if let idx = trimmed.split(separator: " ").last {
                    currentIndex = String(idx)
                }
                vendor = ""
                product = ""
                continue
            }

            if trimmed.contains("Vendor") || trimmed.contains("Product") {
                // Header row — skip
                continue
            }

            // Data row: often two or three tokens
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if parts.count >= 2, currentIndex != nil {
                vendor = parts[0]
                product = parts.dropFirst().joined(separator: " ")
                let title = "\(vendor) \(product)".trimmingCharacters(in: .whitespaces)
                let id = "drive-\(currentIndex!)-\(title)"
                result.append(OpticalDriveInfo(id: id, title: title, bsdName: nil))
                currentIndex = nil
            }
        }

        if result.isEmpty {
            // Fallback: non-empty lines as single entries
            for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if line.contains("Drive") && line.contains("Type") { continue }
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.count > 3 {
                    result.append(OpticalDriveInfo(id: "line-\(i)", title: t, bsdName: nil))
                }
            }
        }

        return result
    }

    /// Best-effort write speed discovery (e.g. 1x, 2x, 4x, ... 16x).
    static func discoverWriteSpeeds(deviceBSDName: String?) async -> [Int] {
        _ = deviceBSDName
        let runner = ProcessRunner()
        let drPath = ToolResolver.drutilExecutable()
        guard FileManager.default.isExecutableFile(atPath: drPath) else {
            return fallbackSpeeds()
        }

        var mergedOutput = ""
        do {
            let (_, statusOut) = try await runner.runCollecting(
                launchPath: drPath,
                arguments: ["status"]
            )
            mergedOutput += statusOut + "\n"
        } catch {}

        do {
            let (_, infoOut) = try await runner.runCollecting(
                launchPath: drPath,
                arguments: ["info"]
            )
            mergedOutput += infoOut + "\n"
        } catch {}

        let parsed = parseWriteSpeeds(from: mergedOutput)
        if parsed.isEmpty {
            return fallbackSpeeds()
        }
        return parsed
    }

    /// Best-effort inserted media detection for auto-selecting capacity profile.
    static func detectInsertedMedia(deviceBSDName: String?) async -> OpticalMediaDetection {
        let runner = ProcessRunner()
        var blobs: [String] = []

        let drPath = ToolResolver.drutilExecutable()
        if FileManager.default.isExecutableFile(atPath: drPath) {
            if let status = try? await runner.runCollecting(
                launchPath: drPath,
                arguments: ["status"]
            ).output {
                blobs.append(status)
            }
            if let info = try? await runner.runCollecting(
                launchPath: drPath,
                arguments: ["info"]
            ).output {
                blobs.append(info)
            }
        }

        let duPath = ToolResolver.diskutilExecutable()
        if FileManager.default.isExecutableFile(atPath: duPath),
           let node = normalizedDiskNode(from: deviceBSDName),
           !node.isEmpty,
           let info = try? await runner.runCollecting(
               launchPath: duPath,
               arguments: ["info", node]
           ).output {
            blobs.append(info)
        }

        let merged = blobs.joined(separator: "\n")
        let profile = BurnProfile.infer(from: merged)
        let label = inferredMediaLabel(from: merged, fallbackProfile: profile)
        return OpticalMediaDetection(profile: profile, label: label)
    }

    private static func parseWriteSpeeds(from text: String) -> [Int] {
        // Extract numbers like 1x, 2.4x, 16x on lines mentioning write speed.
        let lines = text.split(separator: "\n").map(String.init)
        let speedRegex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*x"#, options: [.caseInsensitive])
        var values: Set<Int> = []

        for line in lines {
            let lower = line.lowercased()
            guard lower.contains("write") || lower.contains("burn") else { continue }
            guard let speedRegex else { continue }
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            let matches = speedRegex.matches(in: line, options: [], range: range)
            for m in matches where m.numberOfRanges >= 2 {
                let token = nsLine.substring(with: m.range(at: 1))
                if let d = Double(token) {
                    let rounded = Int(d.rounded())
                    if rounded > 0 { values.insert(rounded) }
                }
            }
        }

        return values.sorted()
    }

    private static func fallbackSpeeds() -> [Int] {
        [1, 2, 4, 6, 8, 12, 16]
    }

    private static func normalizedDiskNode(from bsdName: String?) -> String? {
        guard let raw = bsdName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("/dev/") {
            return String(raw.dropFirst("/dev/".count))
        }
        return raw
    }

    private static func inferredMediaLabel(from text: String, fallbackProfile: BurnProfile?) -> String? {
        let lines = text.split(separator: "\n").map(String.init)
        let keys = [
            "Media Type",
            "Device / Media Name",
            "Disc Type",
            "Medium Type",
            "Type (Bundle)"
        ]

        for line in lines {
            for key in keys where line.localizedCaseInsensitiveContains(key) {
                if let colon = line.firstIndex(of: ":") {
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        return value
                    }
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return fallbackProfile?.rawValue
    }

    /// Best-effort: map first token of `diskutil list` device lines to optical media names.
    private static func bsdNamesForOpticalDrives() async -> [String: String] {
        var map: [String: String] = [:]
        let du = ToolResolver.diskutilExecutable()
        guard FileManager.default.isExecutableFile(atPath: du) else { return map }

        let runner = ProcessRunner()
        do {
            let (_, plistXML) = try await runner.runCollecting(
                launchPath: du,
                arguments: ["list", "-plist"]
            )
            map = parseDiskUtilPlistForOptical(Data(plistXML.utf8))
        } catch {
            return map
        }
        return map
    }

    /// Minimal XML plist scan for optical volumes (no full PlistDecoder dependency on XML).
    private static func parseDiskUtilPlistForOptical(_ data: Data) -> [String: String] {
        guard let xml = String(data: data, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]

        // Split by dict chunks roughly matching disk entries — simplify: look for optical-ish MediaName
        if let regex = try? NSRegularExpression(pattern: "<key>DeviceIdentifier</key>\\s*<string>(disk\\d+)</string>", options: []),
           let mediaRegex = try? NSRegularExpression(pattern: "<key>(MediaName|VolumeName)</key>\\s*<string>([^<]+)</string>", options: []) {
            let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)

            // Walk device blocks heuristically: find /dev/diskN then nearest MediaName
            let devMatches = regex.matches(in: xml, options: [], range: range)
            for devMatch in devMatches {
                guard devMatch.numberOfRanges >= 2,
                      let r = Range(devMatch.range(at: 1), in: xml) else { continue }
                let bsd = "/dev/\(String(xml[r]))"

                let start = devMatch.range.location
                let windowEnd = min(start + 8000, (xml as NSString).length)
                let window = NSRange(location: start, length: windowEnd - start)
                let mediaMatches = mediaRegex.matches(in: xml, options: [], range: window)
                for mm in mediaMatches {
                    guard mm.numberOfRanges >= 3,
                          let mr = Range(mm.range(at: 2), in: xml) else {
                        continue
                    }
                    let name = String(xml[mr])
                    let upper = name.uppercased()
                    if upper.contains("BD") || upper.contains("BLU") || upper.contains("DVD") || upper.contains("CD") || upper.contains("MATSHITA") {
                        let key = name.split(separator: " ").first.map(String.init) ?? name
                        map[key] = bsd
                        break
                    }
                }
            }
        }

        return map
    }
}
