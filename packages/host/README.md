# SoundBridge Host

`SoundBridgeHost` is the background audio process used by SoundBridge on macOS.
It discovers physical output devices, creates shared memory endpoints for the HAL driver, runs DSP, and renders audio to the selected physical device.

## What It Does

- Enumerates physical output devices (excluding SoundBridge/Netcat and virtual/aggregate devices)
- Validates candidate devices (active channels, display-audio jack status, format/rate checks)
- Chooses an operating sample rate at startup from the current/selected physical device
- Creates a per-user session directory (`/private/tmp/com.soundbridge.<uid>`, 0700 + ACL for the driver service)
- Creates one audio ring (`audio-<hash>`, shared with the driver) and one EQ control file (`eq-<hash>`, owner-only) per physical device
- Writes the driver control file (`devices.txt`) atomically
- Starts heartbeat updates for driver/host health signaling
- Starts a CoreAudio HAL output unit and renders `ring buffer -> DSP -> hardware`
- Auto-switches system output to the matching proxy device and forwards proxy volume/mute to the physical device
- Monitors device list/default output changes and sleep/wake recovery hooks

## Architecture

```
SoundBridgeHost
  |- SessionDirectory      (validated per-user IPC directory, atomic file creation)
  |- DeviceDiscovery       (enumerate + validate physical devices)
  |- DeviceRegistry        (tracks devices, writes devices.txt and device-state.json)
  |- SharedMemoryManager   (mappings, generations, heartbeat, RCU render slot)
  |- ProxyDeviceManager    (proxy<->physical mapping, auto-select, volume/mute forwarding, silent bounce)
  |- AudioRenderer         (ring read -> bounds -> EQ/DSP -> gain -> bounds; realtime-safe)
  |- AudioEngine           (HAL output unit; no fallback away from a preferred device)
  |- DeviceMonitor         (CoreAudio listeners, hopped onto the main queue)
  |- BounceRequestListener (token-authenticated, rate-limited reconnect requests)
  |- HostInstanceLock / ParentProcessWatcher
  |- SleepWakeMonitor      (IOKit notifications and wake recovery)
```

Control-plane state is owned by the main queue. The render callback touches only the
render slot and its preallocated buffer.

## Runtime Flow

Startup sequence in `main.swift`:

1. Opens/creates the session directory and takes the single-instance lock (exit code 3 if another host owns it)
2. Enumerates physical output devices and picks the operating sample rate
3. Creates shared memory, starts the heartbeat
4. Writes `devices.txt` (notifies the driver) and registers device listeners
5. Waits for proxies, auto-selects the proxy, bounces once (silently) to recapture apps
6. Starts the HAL output unit on the preferred device only
7. Installs signal handlers, the parent-exit watcher, and the bounce listener

Shutdown (SIGINT/SIGTERM or launching app exits):

- Restores the physical output device while the proxy still exists
- Stops the audio engine, removes `devices.txt` (driver drops proxies), unlinks all mappings

## Device and Sample Rate Behavior

- Supported nominal sample rates are snapped to one of:
  `44100, 48000, 88200, 96000, 176400, 192000`.
- The operating sample rate is chosen at startup from the resolved physical output device.
- Device change handling switches output device routing; current code does not perform a full end-to-end pipeline rebuild on every switch.

## Paths and IPC

- Session directory: `/private/tmp/com.soundbridge.<uid>/` (`devices.txt`, `audio-*`, `eq-*`, `bounce-request`, `host.lock`)
- Device state for the app: `~/Library/Application Support/SoundBridge/device-state.json`
- Volume/mute per device: `~/Library/Application Support/SoundBridge/volume-state.json`

## Key Configuration (`Constants.swift`)

| Setting | Value / Meaning |
|---|---|
| `activeSampleRate` | Runtime-selected sample rate |
| `defaultSampleRate` | Fallback/default sample rate (48000) |
| `defaultChannels` | 2 |
| `defaultDurationMs` | 100 |
| `heartbeatInterval` | 1.0s |
| `deviceWaitTimeout` | 2.0s |
| `cleanupWaitTimeout` | 1.2s (delay before unmapping an unplugged device) |
| `bounceMinInterval` | 2.0s |
| `physicalDeviceSwitchDelay` | 0.5s |
| `wakeRecoveryDelay` | 1.5s |

## Build and test

```bash
cmake -S packages/dsp -B packages/dsp/build && cmake --build packages/dsp/build   # host links libsoundbridge_dsp.a
cd packages/host
swift build -c release
swift test        # IPC files, control-file format, mapping lifetime, bounce tokens
```

## Run

```bash
cd packages/host
./start_host.sh
```

`start_host.sh` launches `.build/release/SoundBridgeHost` when available, otherwise `.build/debug/SoundBridgeHost`.

## Logging

Diagnostics go to unified logging (subsystem `com.soundbridge.host`). Step messages are also printed to stdout, which the app discards in release builds.

## Dependencies

- `CSoundBridgeAudio` (shared memory/ring-buffer C interface)
- `CSoundBridgeDSP` (DSP C API)
- Apple frameworks: `CoreAudio`, `AudioToolbox`, `CoreFoundation`, `IOKit`
