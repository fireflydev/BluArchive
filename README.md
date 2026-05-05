# BluArchive (macOS)

Native SwiftUI macOS app that runs the same workflow as `bluray.sh`:

**TAR → PAR2 → SHA256 manifest → UDF/ISO (`hdiutil makehybrid`) → optional burn (`hdiutil burn`) → optional verify**

## Requirements

- macOS 13+
- Xcode or Swift toolchain (`swift`)
- **par2** (e.g. `brew install par2`)
- Blu-ray writer supported by macOS

## Build CLI binary

```bash
cd BDXLBackupApp
swift build -c release
```

Run the binary (opens GUI):

```bash
open .build/arm64-apple-macosx/release/BDXLBackupApp
# or: swift run -c release
```

## Build `.app` bundle

```bash
chmod +x scripts/create_app_bundle.sh
./scripts/create_app_bundle.sh
```

Output: `build/BluArchive.app`

Open with **right-click → Open** the first time if Gatekeeper prompts.

## Usage

1. **Choose** source folder and output folder.
2. Pick **media profile** (25 / 50 / 100 / 128 GB class) — sizes are **safe payload** limits, not marketing capacity.
3. Set **TAR first** (recommended for reliability) and **PAR2** toggle.
4. If PAR2 is enabled, adjust **PAR2 redundancy** (default 12%).
5. Optionally **burn**; pick drive or enter **BSD device** (e.g. `disk4`).
6. Choose **verify** mode; **deep** runs `hdiutil verify` on the ISO and re-checks TAR checksum when TAR-first is enabled.
7. **Export diagnostics** saves settings + full log.

## Runbook / test matrix

| Step | Check |
|------|--------|
| Preflight | Missing `par2` → clear error in log |
| Small dataset | ISO-only (burn off), quick verify |
| Capacity guard | Source larger than profile safe GiB → rejected before TAR |
| Burn | External writer, slowest speed + `-verify` when verify ≠ None |
| Cancel | Cancel during TAR/PAR2 → process terminates |

## Notes

- Staging directory: `<output>/_bdxl_work` (removed after success unless **Keep staging** is on).
- ISO path: `<output>/<volume label>.iso`
- This app **orchestrates** system tools; it is not a custom disc encoding engine.

## License

Use and modify for personal archival workflows.
