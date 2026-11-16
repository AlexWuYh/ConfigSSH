# ConfigSSH

Native macOS SSH Config manager. The source of truth for connection settings is OpenSSH config, not an app database.

Requires macOS 14+ and a Swift 6 toolchain (Xcode 27.1 is verified locally).

## Commands

- `swift build` — compile the macOS app.
- `swift test` — run parser and configuration fixtures; tests must use temporary files.
- `swift run ConfigSSH` — launch the current Swift Package app on macOS.
- `./scripts/package-macos.sh` — build a local `.app` with the confirmed `cn.wuewa.configssh` Bundle ID. Set `CONFIGSSH_SIGNING_IDENTITY` only when the user's Developer ID certificate is available.

## Repository map

- `Sources/ConfigSSH/`: SwiftUI executable and app entry point.
- `Sources/ConfigSSHCore/`: configuration parsing and other UI-independent logic.
- `Tests/ConfigSSHCoreTests/`: temporary-directory fixtures and regression tests.
- `Assets/` and `scripts/`: generated icon and repeatable macOS packaging.
- `.ai/` (local only, ignored by Git): internal V1 requirements, visual references and safe fixture-based acceptance notes. Never commit or publish this directory, including its history.
- `MILESTONES.md`: current milestone status, evidence, and next work.
- `docs/RELEASING.md`: public tag, asset and professional Release Notes standard.

## Implementation rules

- Track delivery in the order M0 → M1 → M2 → M3 → M4. Work that does not depend on an open M0 decision may advance in parallel; do not mark a milestone complete without recording implementation and verification in `MILESTONES.md`.
- M1 reads `~/.ssh/config` and `Include` files only. Never use the user's real `~/.ssh` as an automated test target.
- Preserve source bytes, line endings, comments, unknown directives, and file/line provenance. If an imported block cannot be located safely, expose it as read-only rather than rewriting it.
- A safely locatable imported Host block may be deleted only by a byte-range-local edit that preserves adjacent rules and comments; independent managed Host files may be deleted whole after diff preview, version checks and backup. Never delete a complex/ambiguous block through the simplified UI.
- Structured global-option updates are limited to `GlobalConfigCatalog`. User-authored whole-file edits of the root `config` are allowed only through diff preview, version/conflict checks, backup, and atomic replacement; never normalize or silently merge the user's text. Do not run `ssh -G` on imported configs to validate it.
- New hosts use one file per alias in `~/.ssh/config.d/`; a named group maps to a single subdirectory. The root `~/.ssh/config` receives only global directives and needed `Include` entries for new hosts; existing root Host blocks remain readable and are not migrated automatically.
- Empty group directories are persistent. Deleting a host must not delete its group; deleting a group must preview and move safe managed host files to ungrouped `config.d/`, refuse collisions or unknown files, and migrate local host metadata/history.
- Group deletion uses a private `Backups/GroupOperations` journal. After partial failure, do not discard the journal or overwrite externally modified files; expose its retry action and test file/metadata rollback with temporary fixtures.
- Derive the default visible group from a host's source directory. Keep groups collapsible in the host list. Installed terminals are discovered at runtime; unrecognized apps need an explicit, direct CLI argument configuration before launching.
- Do not run `ssh -G` automatically on imported configs: `Match exec` can execute local commands.
- The installed Otty 1.6.5 CLI says `-e` uses `/bin/sh -c`; do not build a command from imported aliases with that mode. Probe and use a safe adapter in M3.
- The confirmed Bundle ID is `cn.wuewa.configssh`; temporary preview IDs must not appear in release artifacts. No Developer ID signing credentials are available yet, so unsigned builds are for local validation only.
- Never read private key bytes into application memory, log them, or store SSH passwords. The only private-key copy exception is a single-use, explicitly confirmed local manual snapshot of individually selected, currently indexed regular files, verified byte-for-byte with the system `cmp` tool. Cloud config push/pull never includes keys. Do not claim a terminal launch proves SSH authentication succeeded.
- Plaintext iCloud snapshot creation is disabled in UI and core. New cloud sync writes one AES-GCM encrypted `.cssh` file per device ID; the ID is stored in this Mac's Keychain. A shared passphrase is entered locally and may be saved only to this Mac's Keychain by explicit choice, never to iCloud. Push may replace only this device's file; pull selects a device, decrypts locally, previews diffs and uses `ConfigWriter.commit` with conflict checks and local backups. Never claim local iCloud Drive writes prove upload completion. Test only with temporary folders, never real `~/.ssh` or iCloud Drive.
- Cloud push skips externally located, symlinked, or non-managed Include files only with an explicit preview listing and an acknowledgement that the remote config may be incomplete; the root `config` must still be included. Do not silently claim a complete mirror. Cloud pull still refuses paths outside `config` and managed `config.d/*.conf`.
- Legacy plaintext iCloud snapshots are read-only and not deleted automatically. In-app local snapshot restore still verifies manifest and archived config hashes, refuses external/symlinked destinations, previews diffs, and never auto-restores keys or deletes files absent from the snapshot. The legacy import helper may only copy verified config files into a private local snapshot; no private keys.
- Scanning and snapshot I/O should run off the main actor; the UI must show loading state and preserve drafts when external config changes are detected. Do not run `Match exec` during refresh.
- README screenshots must be real App captures made from a temporary, redacted SSH fixture; never commit the user's actual hosts, addresses, key paths, or unverified mockups as product screenshots. Debug-only `CONFIGSSH_PREVIEW_ROOT` exists for this purpose and must not affect Release builds.
- Key indexing reads `.pub` files only. Key generation runs `/usr/bin/ssh-keygen` in a private temporary directory with a timeout, publishes files using no-replace hard links, refuses existing targets, sets private-key mode to 0600, and never passes passphrase material on a process command line.
- The in-app brand PNG is a SwiftPM resource bundle; `scripts/package-macos.sh` must copy that bundle beside the executable resources, or the packaged app will crash at launch.
- The approved Open C icon source and colour/mono variants live in `Assets/brand/`; regenerate PNG, menu template and `.icns` via `scripts/make-icon.py` with the installed `logo-design` skill renderer. Keep the blue in-app tint consistent with the icon.
- Package MIT `LICENSE` into the app bundle. Do not label a build public-release-ready until `scripts/release-preflight.sh` passes Developer ID Application, stapler, and Gatekeeper checks; local unsigned builds are validation only.
- GitHub tags follow `vMAJOR.MINOR.PATCH`; before pushing a tag, write `.github/release-notes/<tag>.md` following `docs/RELEASING.md` and run `python3 scripts/validate-release-notes.py <tag>`. The tag workflow currently attaches an **unsigned prerelease** ZIP and SHA-256 checksum; it must not claim signed/public-release readiness. Never include `.ai/` in the public tree or its reachable Git history.
- Use native macOS UI and keep the product local-first. Refer to the PRD for product details instead of duplicating them here.
