# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub Security Advisories for this
repository ("Report a vulnerability" on the Security tab). Do not open a public issue.
Include the affected version, macOS version, and reproduction steps. Test against
null or loopback outputs, not headphones, when a report involves gain or routing.

## Trust boundaries

SoundBridge has three processes and one privileged operation:

| Component | Runs as | Trusts |
|---|---|---|
| HAL driver (`SoundBridgeDriver.driver`) | `_coreaudiod`, inside a Core Audio driver service | Only files in the console user's session directory that pass owner, mode, link-count, size, and layout validation |
| Host (`SoundBridgeHost`) | Logged-in user | Its own session directory; values read from shared memory are clamped before use |
| App (`SoundBridgeApp`) | Logged-in user | Its own session directory; the bundled driver only after identity checks |
| Driver installer | root, per user authorization | Nothing from the caller except five validated arguments; it verifies a root-owned staged copy |

### IPC

All IPC files live in `/private/tmp/com.soundbridge.<uid>/`:

- The directory is owned by the user, mode `0700`, and carries one ACL entry that lets
  `_coreaudiod` traverse and list it (it is opened with `O_SEARCH`; the list right only
  matters on kernels without it). Entry names are SHA-256 digests. Other local users cannot list, read, create, or replace
  anything in it. A pre-existing path owned by someone else makes the host fail closed.
- Files are created with `O_EXCL|O_NOFOLLOW` under random temporary names, sized and
  initialized, then atomically renamed into place. Readers open them relative to a
  validated directory descriptor with `O_NOFOLLOW` and check the opened descriptor
  (regular file, owner, `st_nlink == 1`, no group/other bits, exact size).
- `audio-<sha256>`: audio ring and volume/mute. ACL grants `_coreaudiod` read/write.
- `eq-<sha256>`: EQ control only (128 bytes). No ACL: the driver never sees it, and the
  app never maps audio samples or ring geometry.
- `devices.txt`: bounded, versioned device list. ACL grants `_coreaudiod` read.
- `bounce-request`: single-use, time-limited token for "Reconnect Audio".
- `host.lock`: `flock` single-instance lock used instead of process-name matching.
  After taking it, the host deletes every other file in the directory, so buffers left
  by a crashed host do not survive into the next session.

Darwin notifications (`com.soundbridge.devices-changed`, `.bounce-request`,
`.device-state-changed`) carry no authority. Receivers treat them as wake-up hints,
coalesce them, rate-limit them, and re-read the validated files.

### Native memory safety

`RFSharedAudio.h` (protocol `0x00030000`) is shared by driver, host, and app, kept
identical by `tools/check_protocol_sync.sh`.

- Readers validate the header once (magic, version, header size, stereo float32
  format, supported rate, duration, capacity, exact mapping length, device UID hash)
  into a local `RFAudioLayout`, and never read geometry from shared memory again.
- Mapping length for `munmap` is captured at `mmap` time.
- Ring functions take explicit sample counts, bound every index against the local
  capacity, and each index has a single writer; a corrupt distance resyncs only the
  caller's own index.
- The host publishes the active mapping to the render callback through a lock-free
  read-copy-update slot and unmaps only after readers have quiesced. Delayed removals
  carry a token, so a replugged device cannot be torn down by a stale removal. A ring
  is drained when it becomes the active one, so audio buffered while it was inactive
  is never played later.
- When the host replaces a device's file (restart after a crash, sample-rate change),
  the driver's monitor thread notices the new inode, prepares the replacement mapping,
  and hands it to the IO thread, which adopts it without allocating or unmapping.
- The driver's volume/mute controls publish through a mutex that every mapping
  replacement also holds.

`packages/driver/tests` runs these paths under AddressSanitizer, UndefinedBehavior-
Sanitizer, and ThreadSanitizer, including randomized headers and hostile indices.

### Output privacy

- Volume and mute read from shared memory are clamped to `[0, 1]`; invalid values
  mean silence. Samples are bounded before DSP and again after all gain stages.
- "Reconnect Audio" bounces through another SoundBridge proxy (not rendered, so
  silent) or through the physical device with hardware mute engaged. If neither is
  possible, it refuses instead of bypassing software volume. Hardware mute is restored
  only after the proxy is confirmed to be the default output again.
- When a preferred output is known, the host never falls back to a different device.

### Driver installation and updates

- Install, update, repair, and uninstall are decided from bundle identity (bundle ID,
  version, `SoundBridgeProtocolVersion`), not from path existence. Incompatible
  downgrades are refused.
- The root script receives arguments as Apple event parameters quoted with
  AppleScript's `quoted form of`; no value is interpolated into script source.
- As root it copies the bundle into a root-owned staging directory inside the HAL
  plug-in folder, rejects symlinks, checks identifier/version/protocol and (for signed
  builds) the app's Team ID, swaps atomically with rollback, and re-verifies.
- The app then checks the installed bundle and asks Core Audio for the loaded
  driver's identity (plug-in property `'sbvi'`). Success requires that identity to
  match; a driver that is not running, or running without that identity (a build older
  than protocol 3), is reported as "restart required" and keeps prompting.
- If the privileged script is interrupted between moving the old driver aside and
  installing the new one, it restores the previous driver.

### Runtime hardening

Host and app use the hardened runtime with no exceptions (no JIT, unsigned executable
memory, DYLD variables, disabled library validation, or audio input).
`tools/verify_signatures.sh` fails a release if any forbidden entitlement appears, if
components are signed by different teams, or if the driver is missing.

### Release pipeline

- CI (`.github/workflows/ci.yml`) runs all test suites with a read-only token.
- Releases build and test the tag without secrets; a second job in the `release`
  environment signs and notarizes that exact artifact (verified by digest); a third
  job signs the appcast. The Apple signing keychain and the Sparkle update key are
  never present in the same job, third-party DMG tooling runs with the keychain
  locked, and the Sparkle tools are downloaded and digest-verified
  (`tools/fetch_sparkle_tools.sh`) rather than taken from a build artifact.
- Actions are pinned to commit SHAs; `Package.resolved` is committed and builds use
  `--force-resolved-versions`; Sparkle is pinned to an exact version and the bundle
  script checks the embedded framework matches the lock.
- Release bundles require `SPARKLE_FEED_URL` (HTTPS) and `SPARKLE_PUBLIC_ED_KEY`;
  without them Sparkle is not started at all. The appcast is signed with the
  `SPARKLE_PRIVATE_KEY` secret.

Repository settings that code cannot enforce and maintainers must configure:
branch protection on `main` with the CI check required, a `release` environment with
required reviewers, tag protection for `v*`, and secret scanning.

## Known residual risks

- **Same-user processes.** Any process running as the logged-in user can read the audio
  ring, write EQ/volume values, truncate a mapping (crashing its reader with `SIGBUS`),
  or request a bounce. Closing this needs an authenticated Mach/XPC transport with
  capability-passed memory; the HAL driver sandbox constraints must be prototyped first.
- **Session identity in the driver.** The driver serves the console user, found via
  `/dev/console` ownership (falling back to `SCDynamicStoreCopyConsoleUser`). This
  must be verified on each supported macOS version.
- **Muted playback still flows through the ring.** Mute is applied by the host after
  reading; it does not stop audio from reaching shared memory.
- **App Sandbox is disabled** for app and host; entitlements alone do not restrict
  network or file access.
