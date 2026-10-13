# Privacy and data retention

SoundBridge processes audio locally. It has no analytics and sends no audio anywhere.

## What is stored

| Data | Location | Lifetime |
|---|---|---|
| Routed playback audio (last ~20–100 ms) | Shared memory in `/private/tmp/com.soundbridge.<uid>/audio-*`, owner-only plus the Core Audio driver service | Deleted when the host quits, and anything left by a crash is deleted at the next launch |
| EQ values | `/private/tmp/com.soundbridge.<uid>/eq-*` (owner-only) and app preferences (`eq_<device UID>_*`) | Preferences persist until reset |
| Output device names and UIDs | `devices.txt` in the session directory; `~/Library/Application Support/SoundBridge/device-state.json` | Session file removed on quit; `device-state.json` persists |
| Per-device volume and mute | `~/Library/Application Support/SoundBridge/volume-state.json` | Persists until reset |
| Diagnostics | Unified logging (`com.soundbridge.driver`, `com.soundbridge.host`, `com.soundbridge.app`); device names and UIDs are logged as private | macOS log retention |

Only playback routed to a SoundBridge device passes through it. SoundBridge does not
record from microphones. Mute silences output but does not stop audio from reaching the
shared buffer.

## Network

If an update feed is configured for the build, Sparkle checks it over HTTPS according to
the "Automatically check for updates" setting. System profile reporting is disabled.
Builds without a configured feed make no update requests.

## Deleting data

"Uninstall Driver" in the menu removes the system driver. Tick "Also delete my
SoundBridge settings, EQ and logs" to additionally remove Application Support and log
folders, all app preferences (including per-device EQ), and the session directory. The
result, including anything that could not be removed, is shown afterwards. Cancelling
the administrator prompt changes nothing.

Uninstalling the driver affects all users of the Mac; each user's own data is deleted
only from their account.
