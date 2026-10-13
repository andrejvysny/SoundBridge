# SoundBridge HAL Driver

A CoreAudio HAL plug-in that creates virtual proxy output devices. Audio sent to a proxy
is converted to stereo float32 and written into a shared-memory ring that the host
process reads, processes, and renders to the real device.

The driver is loaded by Core Audio from `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver`
and runs as `_coreaudiod` inside a Core Audio driver service process.

## Files

| File | Purpose |
|---|---|
| `src/Plugin.cpp` | Plug-in factory, proxy device lifecycle, device sync loop, `'sbvi'` identity property |
| `src/AudioHandler.{hpp,cpp}` | Per-device IO/control handler, volume/mute controls |
| `src/SharedMapping.hpp` | Validated session directory, control file, and mapping access (header-only, tested) |
| `src/StreamConversion.hpp` | HAL buffer to stereo float32 conversion and resampler (header-only, tested) |
| `src/SoundBridgeDevice.hpp` | Device with drift-free `GetZeroTimeStamp` |
| `include/RFSharedAudio.h` | Shared-memory protocol and ring buffer (`0x00030000`) |
| `include/RFSecureIPC.h` | Session directory, file validation, control-file parser, bounce token |
| `tests/` | Standalone native harness (ASan/UBSan/TSan) |
| `Info.plist` | Bundle metadata, factory UUID, `SoundBridgeProtocolVersion` |

`include/RFSharedAudio.h` and `include/RFSecureIPC.h` are copied into the host and app
packages; `tools/check_protocol_sync.sh` fails if they drift (`--fix` copies them).

## IPC

Everything lives in the console user's session directory
`/private/tmp/com.soundbridge.<uid>/` (mode `0700`, ACL entry for `_coreaudiod`). See
`SECURITY.md` for the full model.

- **Session owner**: `/dev/console` owner, falling back to `SCDynamicStoreCopyConsoleUser`.
  At the login window there is no session and no proxies.
- **`devices.txt`**: header `SOUNDBRIDGE-DEVICES 3`, then `<uid>\t<name>` lines, at most
  32 devices and 64 KiB. Any malformed or untrusted file is ignored as a whole and the
  current devices are kept.
- **`audio-<sha256(uid)[0..16]>`**: `RFSharedAudio` header (256 bytes) + ring. Opened
  with `O_NOFOLLOW` relative to the validated directory, checked with `fstat`
  (regular, owner, one link, no group/other bits), mapped at its exact size, and
  validated into a local `RFAudioLayout` including the device UID hash.

## Device lifecycle

A monitor thread owns `SyncDevices()`. It runs every second, or sooner when the
`com.soundbridge.devices-changed` notification arrives (bursts collapse; syncs are at
least 100 ms apart). A device is desired when it is listed in `devices.txt` and its
host heartbeat changed within 15 seconds. Removed devices cannot be re-added for 10
seconds.

Proxies are named `"<Name> (SoundBridge)"` with UID `"<UID>-soundbridge"`, 48 kHz stereo,
mixing enabled.

## Audio path

- **`OnStartIO`** (first client): opens and validates the mapping (up to 15 attempts with
  backoff), preallocates conversion buffers, publishes cached volume/mute, and prefills
  half a ring of silence.
- **`OnWriteMixedOutput`** (IO thread, no allocation or logging): updates the driver
  heartbeat, converts interleaved little-endian PCM (float32/64, int16/24/32, 1–16
  channels; mono is duplicated, extra channels dropped) to stereo float32, compensates
  timestamp gaps, applies sample-rate conversion and ±0.15% drift correction, and writes
  with `rf_ring_write`. Unsupported or oversized buffers are dropped and counted.
- **`OnStopIO`** (last client): swaps the mapping out under the control mutex and unmaps
  it with the locally captured length.

The ring is single-producer/single-consumer: the driver only writes `write_index` and
drops frames that do not fit; the host only writes `read_index`.

## Build and test

```sh
cmake -S packages/driver -B packages/driver/build -DCMAKE_BUILD_TYPE=Release
cmake --build packages/driver/build          # -> build/SoundBridgeDriver.driver

make test-native                             # ASan+UBSan and TSan harness
```

## Install for development

```sh
cd packages/driver && ./install.sh && sudo killall coreaudiod
./uninstall.sh && sudo killall coreaudiod
```

Released apps install through the in-app installer (`DriverInstaller`), which verifies
bundle identity, protocol, and signature before replacing the driver.

## Logging

Unified logging only (subsystem `com.soundbridge.driver`); device names and UIDs are
private, pointers and audio data are never logged.

```sh
log show --predicate 'subsystem == "com.soundbridge.driver"' --last 5m
```

## Troubleshooting

| Symptom | Check |
|---|---|
| No proxy devices | Host running? `ls -le /private/tmp/com.soundbridge.$(id -u)/` should show `devices.txt` and `audio-*` with a `_coreaudiod` ACL |
| "Rejected shared memory: protocol version mismatch" | Driver and app versions differ; update the driver from the app |
| "Ignoring malformed or untrusted control file" | Session files have wrong owner/mode or were edited; quit SoundBridge and delete the session directory |
| Driver not loading | Verify install path and restart `coreaudiod` |
