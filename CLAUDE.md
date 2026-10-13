# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

SoundBridge is a macOS 13+ menu bar app that adds software volume control (plus EQ) to fixed-volume HDMI/DisplayPort outputs. It does this by inserting a virtual CoreAudio HAL proxy device in front of the physical device. It has no Xcode project: everything builds with CMake (C/C++) and SwiftPM (Swift), driven by `Makefile` and `tools/*.sh`.

## Setup

```bash
git submodule update --init --recursive   # libASPL at packages/driver/vendor/libASPL; driver build fails without it
make install-deps                         # only checks that cmake + swift exist
```

## Build / run

| Command | What it does |
|---|---|
| `make build` | `update-version` + `tools/build_release.sh`: DSP → driver → host → app (universal arm64+x86_64 via two `swift build --triple` runs + `lipo`) → `dist/SoundBridge.app` |
| `make quick` | Rebuild only the two Swift packages (universal) + re-bundle. Use after Swift-only changes |
| `make bundle` | Only `tools/create_app_bundle.sh` (wipes and recreates `dist/`) |
| `make run` | `open dist/SoundBridge.app` |
| `make dev` | `reset` + build + bundle + open (shows onboarding again) |
| `make reset` | Kills app/host, **uninstalls the driver from `/Library/Audio/Plug-Ins/HAL` (admin prompt, restarts coreaudiod)**, clears onboarding `defaults` for `com.soundbridge.menubar` |
| `make sign` / `verify` / `dmg` / `full-release` | Developer ID signing, signature check, DMG. Needs certificates |

Gotchas:
- `make build` runs `tools/update_versions.sh`, which rewrites the version in `apps/mac/SoundBridgeApp/Info.plist`, `packages/host/Info.plist`, `packages/driver/Info.plist`, `packages/driver/VERSION`, and `packages/driver/CMakeLists.txt` using the latest git tag. That can leave the working tree dirty.
- The host links a prebuilt `libsoundbridge_dsp.a` from `packages/dsp/build` (see the `unsafeFlags` in `packages/host/Package.swift`). Build DSP before the host.
- CMake Debug builds of DSP and the driver turn on AddressSanitizer.

Building one component at a time:
```bash
cmake -S packages/dsp -B packages/dsp/build -DCMAKE_BUILD_TYPE=Release && cmake --build packages/dsp/build
cmake -S packages/driver -B packages/driver/build -DCMAKE_BUILD_TYPE=Release && cmake --build packages/driver/build
(cd packages/host && swift build -c release)          # run: ./start_host.sh (RF_TEST_TONE=1 swaps in a 440 Hz test tone for the ring buffer)
(cd apps/mac/SoundBridgeApp && swift build)            # dev run: swift run [--reset-onboarding]
```
When the app runs outside a bundle, it looks for the host binary in `packages/host/.build/...`, relative to its own location or to `$SOUNDBRIDGE_ROOT`.

Reload the driver during development: `cd packages/driver && ./install.sh && sudo killall coreaudiod` (`./uninstall.sh` removes it). Driver logs: `log show --predicate 'subsystem == "com.soundbridge.driver"' --last 5m` (unified logging only; there is no file log).

## Tests

`make test-all` runs everything below (it is what CI and the release job run).

- **Protocol sync**: `tools/check_protocol_sync.sh` (`--fix` copies the driver headers to host/app).
- **Native harness (C/C++)**: `make test-native` builds `packages/driver/tests` twice (ASan+UBSan, TSan) and covers layout validation, ring bounds, EQ SeqLock, control-file parser, IPC file validation, stream conversion, and the host render slot. Filter: `packages/driver/tests/build-asan/soundbridge_protocol_tests <name-substring>`.
- **DSP (C++)**: `make test` (binary is `packages/dsp/build/tests/soundbridge_dsp_tests`). No CLI filter; comment out `REGISTER_TEST` lines in `tests/test_main.cpp`. New tests need a declaration and a `REGISTER_TEST` there, plus the source file in `tests/CMakeLists.txt`. "0 passed" is cosmetic; the exit code reflects failures.
- **Host (Swift)**: `make test-host` (builds DSP first). Tests use the real per-user session directory with unique `sbtest-*` UIDs.
- **App (Swift, XCTest + SwiftCheck)**: `make test-app` (`swift test --force-resolved-versions`). Single test: `swift test --filter EQUnitTests/testPresetHas10Bands`. `PrivilegedInstallScriptTests` runs the real installer script unprivileged against a scratch HAL directory.
- The HAL driver itself (inside coreaudiod) has no automated test; verify on macOS manually.

## Architecture

There are four components and three processes. The driver runs **inside `coreaudiod`** and is not its own process.

```
App (SwiftUI menu bar)   Driver (C++ HAL plugin, libASPL)        Host (Swift CLI)                  Physical device
apps/mac/SoundBridgeApp  packages/driver/src/Plugin.cpp          packages/host  ── links ── packages/dsp (C ABI)
```

### IPC channels (the cross-file part)

All session files live in `/private/tmp/com.soundbridge.<uid>/` (owner `0700` + ACL letting `_coreaudiod` traverse). Files are created `O_EXCL|O_NOFOLLOW` and atomically renamed; readers open relative to a validated dir fd and check `fstat` (regular, owner, 1 link, no group/other bits, exact size). See `SECURITY.md`.

| Channel | Writer → Reader | Purpose |
|---|---|---|
| `devices.txt` (`SOUNDBRIDGE-DEVICES 3` + `uid\tname` lines; ACL read for driver) + notify `com.soundbridge.devices-changed` | Host → Driver | Devices that need proxies. Driver monitor thread owns `SyncDevices()` (1 s poll, notify only wakes it). Adds a proxy while the host heartbeat changed <15 s ago; 10 s re-add cooldown. Malformed file = keep current devices |
| `audio-<sha256(uid) hex32>` (`RFSharedAudio`, ACL rw for driver) | Driver → Host: ring, volume/mute. Both: heartbeats | Created by host. Driver maps on `OnStartIO`. Header also binds the device UID hash |
| `eq-<hash>` (`RFEQControl`, 128 B, owner-only) | App → Host (SeqLock) | EQ snapshot. App never maps the audio ring |
| `bounce-request` (32 B `RFBounceToken`) + notify `com.soundbridge.bounce-request` | App → Host | Reconnect request; host only acts on a fresh, unseen token, rate limited |
| `host.lock` (`flock`) | Host holds, App checks | Single instance / "is host running" (no `pgrep`) |
| `~/Library/Application Support/SoundBridge/device-state.json` + notify `com.soundbridge.device-state-changed` | Host → App | Device list and active device |
| CoreAudio `kAudioDevicePropertyVolumeScalar` / mute on the proxy | App/system → Driver | Driver controls publish into the ring header; host clamps and applies as smoothed gain and forwards to the physical device |
| CoreAudio plug-in property `'sbvi'` | Driver → App | Loaded driver version + protocol (used to verify updates) |

Proxy devices are named `"<Name> (SoundBridge)"` with UID `"<UID>-soundbridge"`. Host device discovery skips any device whose name contains "SoundBridge".

### Shared memory protocol — keep copies in sync
`RFSharedAudio.h` (protocol `0x00030000`) and `RFSecureIPC.h` live in `packages/driver/include/` and are copied to `packages/host/Sources/CSoundBridgeAudio/include/` and `apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/`. Edit the driver copy, then `tools/check_protocol_sync.sh --fix`. Bump `RF_AUDIO_PROTOCOL_VERSION` and `SoundBridgeProtocolVersion` in `packages/driver/Info.plist` together on any layout change (static asserts pin offsets). Don't include `<stdatomic.h>` there: its macros break libc++ before C++23; use the `RF_ATOMIC_*` builtins. Host-only `RFRenderSlot.h` is not synced.

Transport is fixed stereo float32. Readers validate the header once into a local `RFAudioLayout` and must never re-read geometry; ring calls take explicit sample counts; driver writes only `write_index`, host only `read_index`.

DSP headers are also copied into `packages/host/Sources/CSoundBridgeDSP/include/`. That copy has **already diverged** from `packages/dsp/include/`: it lacks `update_band_frequency/q` and denormal suppression, and `soundbridge_stats_t` is missing the `peak_*_db` fields, so the struct layouts differ. Sync it before the host uses any of those.

### Host (`packages/host/Sources/SoundBridgeHost`)
`main.swift` holds global singletons and a numbered startup sequence: session dir + `host.lock` (exit 3 if held) → discover devices → pick sample rate → create mappings + heartbeat → `devices.txt` → wait for proxies → `ProxyDeviceManager.autoSelectProxy()` → start the HAL output unit on the preferred device only (no fallback). Control-plane state is owned by the main queue (CoreAudio listener callbacks hop there). `SharedMemoryManager` publishes the active device's mapping to the render callback through an RCU slot (`RFRenderSlot.h`) and unmaps only after readers quiesce; delayed unplug removals use claim tokens. `AudioRenderer.render` runs on the realtime thread: slot acquire → ring read → sanitize → EQ snapshot diff → DSP (reset on NaN) → gain → final ±1 clamp; keep it free of allocation, locks, logging, `print`, and Swift strings. Bounce goes through another proxy (silent) or muted physical device, else is refused. Cleanup (signal or parent exit): restore physical device → stop engine → remove `devices.txt` → unlink mappings; no `killall coreaudiod`. Per-device volume persists in `volume-state.json` (clamped).

### Driver (`packages/driver/src`)
`Plugin.cpp`: factory `SoundBridgeDriverPluginFactory` (UUID in `Info.plist`), monitor thread + `SyncDevices()`, `'sbvi'` property. `AudioHandler.cpp`: IO handler; `OnWriteMixedOutput` (IO thread, serialized with Start/StopIO by libASPL's io mutex) converts via `StreamConversion.hpp`, compensates timestamp gaps, SRC + drift, then `rf_ring_write`; volume/mute controls publish under `mappingMutex_`. `SharedMapping.hpp`: validated dir/control/mapping access. Session owner = `/dev/console` owner (fallback `SCDynamicStoreCopyConsoleUser`). No file logging. Needs a `coreaudiod` restart to reload. `CMakeLists.bgm.broken` is dead.

### DSP (`packages/dsp`)
A C++17 RBJ-biquad 10-band EQ + limiter + DC blocker behind the C ABI in `include/soundbridge_dsp.h`. That header documents which calls are realtime-safe. `bridge/` (ObjC++) is built but not used by the host, which calls the C API directly.

### App (`apps/mac/SoundBridgeApp/Sources`)
`App/SoundBridgeApp.swift` (`AppDelegate`) handles onboarding vs. menu bar mode, driver status (`DriverStatus.decide` from bundled/installed/loaded identity: install/update/repair/reload/downgrade refusal; prompts every launch until fixed), Sparkle (started only if `SUFeedURL` is https and `SUPublicEDKey` is a 32-byte key; release bundles get them from `SPARKLE_FEED_URL`/`SPARKLE_PUBLIC_ED_KEY`), and termination. `HostProcessController` launches/stops only its own host child (lock-based detection, 3 s graceful stop, output to /dev/null in release). `DriverInstaller` runs the fixed root script in `PrivilegedRunner.swift` (arguments passed as Apple event params, `quoted form of`; staged root-owned copy verified for bundle ID/version/protocol/Team ID, atomic swap + rollback) then verifies installed and loaded identity. `UninstallCoordinator` separates driver removal from data deletion; cancel changes nothing. The UI EQ has 3 bands (bass/mids/treble), and `EQController` maps them with weights onto the 10 DSP bands, persisting per device in `UserDefaults`, writing only the `eq-*` control file. Setting `ENABLE_LIQUID_GLASS=1` (or building with a macOS 26 SDK) defines `LIQUID_GLASS_AVAILABLE`.

## Conventions
- Conventional commits (`feat:`, `fix:`, `perf:`, `chore:`, `ci:`, `docs:`). `.github/cliff.toml` (git-cliff) groups them into the changelog (`make changelog VERSION=vX.Y.Z`).
- CI: `.github/workflows/ci.yml` (read-only token) runs `make test-all` + driver build. Actions are pinned to commit SHAs; keep it that way.
- Releases: publishing a GitHub release tagged `vX.Y.Z` triggers `.github/workflows/release.yml`: a secret-free `build` job (tag validation, `make test-all`, `REQUIRE_RELEASE_COMPONENTS=1 tools/build_release.sh`) and a `sign` job in the `release` environment (sign, `verify_signatures.sh` entitlement/team allowlist, notarize, DMG, signed Sparkle appcast, `gh release upload`). Needs repo vars `SPARKLE_FEED_URL`, `SPARKLE_PUBLIC_ED_KEY` and secret `SPARKLE_PRIVATE_KEY`. The driver is re-versioned only if `packages/driver/{src,include,CMakeLists.txt,Info.plist}` changed since the last tag.
- `apps/mac/SoundBridgeApp/Package.resolved` is committed; Sparkle is pinned `exact:`. Entitlements for host/app carry no hardened-runtime exceptions; adding one requires `SECURITY.md` + `tools/verify_signatures.sh` changes.
- A global PostToolUse hook runs `clang-format` on C/C++ edits; the repo `.clang-format` matches the existing 4-space style.
- Some code comments and the Chinese sections of `README.md` predate the English UI translation. Package READMEs are partly stale (the host README describes `DSPProcessor`/`PresetMonitor`/`preset.json`, which no longer exist; EQ now flows through shared memory). Trust the code.
