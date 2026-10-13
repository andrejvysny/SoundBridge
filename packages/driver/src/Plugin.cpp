// SoundBridge HAL driver: plugin factory and proxy device lifecycle.

#include "AudioHandler.hpp"
#include "Log.hpp"
#include "SoundBridgeDevice.hpp"

#include <aspl/Driver.hpp>
#include <CoreAudio/AudioServerPlugIn.h>

#include <notify.h>

#include <chrono>
#include <condition_variable>
#include <map>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifndef SOUNDBRIDGE_DRIVER_VERSION
#define SOUNDBRIDGE_DRIVER_VERSION "0.0.0"
#endif

namespace {

using namespace soundbridge;
using Clock = std::chrono::steady_clock;

constexpr UInt32 kDefaultSampleRate = 48000;
constexpr UInt32 kDefaultChannels = 2;
// AudioServerPlugIn.h documents a minimum zero timestamp period of 10923 frames.
constexpr UInt32 kZeroTimeStampPeriodFrames = 16384;
constexpr UInt32 kSafetyOffsetFrames = 128;
constexpr UInt32 kPresentationLatencyFrames = 512;
static_assert(kZeroTimeStampPeriodFrames >= 10923, "ZeroTimeStampPeriod must satisfy CoreAudio minimum");

constexpr auto kHeartbeatTimeout = std::chrono::seconds(15);
constexpr auto kDeviceCooldown = std::chrono::seconds(10); // prevents rapid remove/re-add cycling
constexpr auto kPollInterval = std::chrono::seconds(1);
constexpr auto kMinSyncSpacing = std::chrono::milliseconds(100);

// Custom plugin property exposing the loaded driver identity to the app:
// CFDictionary { "version": CFString, "protocol": CFNumber }.
constexpr AudioObjectPropertySelector kDriverInfoProperty = 'sbvi';

struct HeartbeatState {
    uint64_t lastValue = 0;
    Clock::time_point lastChange = Clock::now();
};

struct ProxyDevice {
    std::shared_ptr<aspl::Device> device;
    std::shared_ptr<UniversalAudioHandler> handler;
};

struct GlobalState {
    std::shared_ptr<aspl::Context> context;
    std::shared_ptr<aspl::Plugin> plugin;
    std::shared_ptr<aspl::Driver> driver;

    // Owned by whoever holds syncMutex (monitor thread after startup).
    std::mutex syncMutex;
    std::map<std::string, ProxyDevice> devices;
    std::map<std::string, HeartbeatState> heartbeats; // keyed by "<owner>/<uid>"
    std::map<std::string, Clock::time_point> removalTimes;

    std::thread monitorThread;
    std::mutex wakeMutex;
    std::condition_variable wakeCondition;
    bool wakeRequested = false;
};

GlobalState* g_state = nullptr;

ProxyDevice CreateProxyDevice(const std::string& name, const std::string& uid) {
    aspl::DeviceParameters params;
    params.Name = name + " (SoundBridge)";
    params.DeviceUID = uid + "-soundbridge";
    params.Manufacturer = "SoundBridge";
    params.SampleRate = kDefaultSampleRate;
    params.ChannelCount = kDefaultChannels;
    params.EnableMixing = true;
    params.ZeroTimeStampPeriod = kZeroTimeStampPeriodFrames;
    params.SafetyOffset = kSafetyOffsetFrames;
    params.Latency = kPresentationLatencyFrames;

    auto device = std::make_shared<SoundBridgeDevice>(g_state->context, params);
    auto stream = device->AddStreamAsync(aspl::Direction::Output);

    auto volumeControl = std::make_shared<SoundBridgeVolumeControl>(g_state->context, aspl::VolumeControlParameters{});
    auto muteControl = std::make_shared<SoundBridgeMuteControl>(g_state->context, aspl::MuteControlParameters{});
    device->AddVolumeControlAsync(volumeControl);
    device->AddMuteControlAsync(muteControl);
    stream->AttachVolumeControl(volumeControl);
    stream->AttachMuteControl(muteControl);

    auto handler = std::make_shared<UniversalAudioHandler>(uid);
    handler->PublishVolume(volumeControl->GetScalarValue());
    handler->PublishMute(muteControl->GetIsMuted());
    volumeControl->SetHandler(handler);
    muteControl->SetHandler(handler);
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);
    return ProxyDevice{device, handler};
}

bool IsInCooldown(const std::string& uid) {
    auto it = g_state->removalTimes.find(uid);
    return it != g_state->removalTimes.end() && Clock::now() - it->second < kDeviceCooldown;
}

bool HostHeartbeatFresh(int dirfd, uid_t owner, const std::string& uid) {
    auto mapping = SharedAudioMapping::Open(dirfd, owner, uid, false, nullptr);
    if (!mapping || rf_get_host_connected(mapping->Memory()) == 0) return false;
    const uint64_t heartbeat = rf_get_host_heartbeat(mapping->Memory());

    auto& state = g_state->heartbeats[std::to_string(owner) + "/" + uid];
    const auto now = Clock::now();
    if (heartbeat != state.lastValue) {
        state.lastValue = heartbeat;
        state.lastChange = now;
    }
    return now - state.lastChange < kHeartbeatTimeout;
}

void SyncDevices() {
    std::lock_guard<std::mutex> lock(g_state->syncMutex);

    std::map<std::string, std::string> desired;
    uid_t owner = 0;
    UniqueFd dir = OpenConsoleSessionDir(&owner);
    if (dir) {
        std::vector<ControlDevice> entries;
        switch (ReadControlFile(dir.Get(), owner, &entries)) {
            case ControlFileStatus::Invalid:
                RF_LOG_ERROR("Ignoring malformed or untrusted control file");
                return; // keep current devices rather than acting on bad input
            case ControlFileStatus::Missing: break;
            case ControlFileStatus::Ok:
                for (const auto& entry : entries) {
                    if (HostHeartbeatFresh(dir.Get(), owner, entry.uid)) {
                        desired[entry.uid] = entry.name;
                    }
                }
                break;
        }
    }

    for (const auto& [uid, name] : desired) {
        if (g_state->devices.count(uid) || IsInCooldown(uid)) continue;
        auto proxy = CreateProxyDevice(name, uid);
        g_state->plugin->AddDevice(proxy.device);
        g_state->devices[uid] = proxy;
        g_state->removalTimes.erase(uid);
        RF_LOG_INFO("Added proxy device");
    }

    // A restarted host replaces its files; follow them instead of writing into
    // an unlinked mapping the new host cannot read.
    for (const auto& [uid, proxy] : g_state->devices) {
        if (desired.count(uid)) proxy.handler->RefreshIfReplaced(dir.Get(), owner);
    }

    for (auto it = g_state->devices.begin(); it != g_state->devices.end();) {
        if (desired.count(it->first)) {
            ++it;
            continue;
        }
        g_state->plugin->RemoveDevice(it->second.device);
        g_state->removalTimes[it->first] = Clock::now();
        it = g_state->devices.erase(it);
        RF_LOG_INFO("Removed proxy device");
    }
}

// Darwin notifications are unauthenticated: they only wake the monitor, which
// re-reads validated state. Bursts collapse into one sync.
void RequestSync() {
    {
        std::lock_guard<std::mutex> lock(g_state->wakeMutex);
        g_state->wakeRequested = true;
    }
    g_state->wakeCondition.notify_one();
}

void MonitorLoop() {
    int token = 0;
    const uint32_t status = notify_register_dispatch("com.soundbridge.devices-changed", &token,
                                                     dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                                                     ^(int) { RequestSync(); });
    if (status != NOTIFY_STATUS_OK) {
        RF_LOG_ERROR("Darwin notification registration failed (%u), polling only", status);
    }

    for (;;) {
        {
            std::unique_lock<std::mutex> lock(g_state->wakeMutex);
            g_state->wakeCondition.wait_for(lock, kPollInterval, [] { return g_state->wakeRequested; });
            g_state->wakeRequested = false;
        }
        SyncDevices();
        std::this_thread::sleep_for(kMinSyncSpacing);
    }
}

CFPropertyListRef CopyDriverInfo() {
    CFStringRef version =
        CFStringCreateWithCString(kCFAllocatorDefault, SOUNDBRIDGE_DRIVER_VERSION, kCFStringEncodingUTF8);
    SInt64 protocolValue = RF_AUDIO_PROTOCOL_VERSION;
    CFNumberRef protocol = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &protocolValue);
    const void* keys[] = {CFSTR("version"), CFSTR("protocol")};
    const void* values[] = {version, protocol};
    CFDictionaryRef info = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    CFRelease(version);
    CFRelease(protocol);
    return info;
}

std::shared_ptr<aspl::Driver> CreateSoundBridgeDriver() {
    g_state = new GlobalState();
    g_state->context = std::make_shared<aspl::Context>();

    aspl::PluginParameters pluginParams;
    pluginParams.Manufacturer = "SoundBridge";
    g_state->plugin = std::make_shared<aspl::Plugin>(g_state->context, pluginParams);
    g_state->plugin->RegisterCustomProperty(kDriverInfoProperty, std::function<CFPropertyListRef()>(CopyDriverInfo),
                                            std::function<void(CFPropertyListRef)>{});

    SyncDevices();
    g_state->monitorThread = std::thread(MonitorLoop);
    g_state->driver = std::make_shared<aspl::Driver>(g_state->context, g_state->plugin);

    RF_LOG_INFO("Driver %{public}s ready (protocol 0x%x)", SOUNDBRIDGE_DRIVER_VERSION, RF_AUDIO_PROTOCOL_VERSION);
    return g_state->driver;
}

} // namespace

extern "C" void* SoundBridgeDriverPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    (void)allocator;
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return nullptr;
    static std::shared_ptr<aspl::Driver> driver = CreateSoundBridgeDriver();
    return driver->GetReference();
}
