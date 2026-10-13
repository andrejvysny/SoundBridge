#include "AudioHandler.hpp"

#include "Log.hpp"

#include <CoreAudio/AudioServerPlugIn.h>
#include <SystemConfiguration/SystemConfiguration.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <thread>

namespace soundbridge {

namespace {

constexpr int kFillTargetDivisor = 2;       // keep ring near 50% full
constexpr int kFillDeadbandPercent = 20;    // ignore fill variance within ±20%
constexpr double kMaxDriftAdjustPpm = 1500; // ±0.15% drift correction

// Largest HAL IO buffer we accept without allocating on the IO thread.
constexpr uint32_t kMaxIOFrames = 16384;
// Worst-case SRC expansion: 44.1 kHz stream into a 192 kHz ring plus drift headroom.
constexpr double kMaxResampleRatio = (192000.0 / 44100.0) * 1.01;

constexpr int kConnectAttempts = 15;
constexpr int kConnectBaseDelayMs = 30;

} // namespace

UniqueFd OpenConsoleSessionDir(uid_t* outOwner) {
    uid_t owner = 0;
    if (rf_ipc_console_uid(&owner) != 0) {
        uid_t uid = 0;
        gid_t gid = 0;
        CFStringRef user = SCDynamicStoreCopyConsoleUser(nullptr, &uid, &gid);
        if (user) CFRelease(user);
        if (!user || uid == 0) return UniqueFd();
        owner = uid;
    }
    UniqueFd dir(rf_ipc_open_dir(owner));
    if (dir && outOwner) *outOwner = owner;
    return dir;
}

UniversalAudioHandler::UniversalAudioHandler(std::string deviceUID) : deviceUID_(std::move(deviceUID)) {}

UniversalAudioHandler::~UniversalAudioHandler() {
    Disconnect();
}

OSStatus UniversalAudioHandler::OnStartIO() {
    // A failed StartIO is never paired with StopIO, so only count successful starts.
    if (ioClientCount_ > 0) {
        if (!mapping_) return kAudioHardwareUnspecifiedError;
        ioClientCount_++;
        return kAudioHardwareNoError;
    }
    ioClientCount_++;

    // The host may still be creating its files right after launch.
    for (int attempt = 1; attempt <= kConnectAttempts; attempt++) {
        if (Connect()) {
            RF_LOG_INFO("Connected on attempt %d", attempt);
            return kAudioHardwareNoError;
        }
        if (attempt < kConnectAttempts) {
            const int delay = kConnectBaseDelayMs * (1 << std::min(attempt - 1, 6));
            std::this_thread::sleep_for(std::chrono::milliseconds(delay));
        }
    }

    ioClientCount_--;
    RF_LOG_ERROR("StartIO failed: host session unavailable for %{private}s", deviceUID_.c_str());
    return kAudioHardwareUnspecifiedError;
}

void UniversalAudioHandler::OnStopIO() {
    if (ioClientCount_ <= 0) {
        RF_LOG_ERROR("StopIO without matching StartIO");
        return;
    }
    if (--ioClientCount_ == 0) {
        Disconnect();
        const uint64_t dropped = droppedWrites_.exchange(0);
        if (dropped > 0) RF_LOG_INFO("IO stopped, dropped %llu unsupported/oversized writes", dropped);
    }
}

bool UniversalAudioHandler::Connect() {
    uid_t owner = 0;
    UniqueFd dir = OpenConsoleSessionDir(&owner);
    if (!dir) return false;

    OpenResult result;
    auto mapping = SharedAudioMapping::Open(dir.Get(), owner, deviceUID_, true, &result);
    if (!mapping) {
        if (result.layout != RF_LAYOUT_OK) {
            RF_LOG_ERROR("Rejected shared memory: %{public}s", rf_layout_status_string(result.layout));
        }
        return false;
    }

    const RFAudioLayout& layout = mapping->Layout();
    const size_t maxResampledFrames = static_cast<size_t>(std::ceil(kMaxIOFrames * kMaxResampleRatio)) + 16;
    interleaved_.assign(kMaxIOFrames * 2, 0.0f);
    resampled_.assign(maxResampledFrames * 2, 0.0f);
    silence_.assign(layout.capacity_frames, 0.0f); // capacity/2 frames of stereo silence
    resampler_.Reset();
    hasLastTimestamp_ = false;

    RFSharedAudio* mem = mapping->Memory();
    rf_set_driver_connected(mem, true);
    // Half a ring of silence so the host's first callbacks do not underrun.
    rf_ring_write(mem, &layout, silence_.data(), silence_.size());

    handoff_.Clear();
    const MappingIdentity identity = mapping->Identity();

    // Publish cached controls under the same lock Publish*() takes, so a change
    // racing with this connect is never lost.
    std::lock_guard<std::mutex> lock(mappingMutex_);
    mapping_ = std::move(mapping);
    connectedDevice_.store(identity.device);
    connectedInode_.store(identity.inode);
    rf_store_volume_scalar(mem, volume_.load());
    rf_store_mute_state(mem, muted_.load());
    return true;
}

void UniversalAudioHandler::Disconnect() {
    std::unique_ptr<SharedAudioMapping> old;
    {
        std::lock_guard<std::mutex> lock(mappingMutex_);
        old = std::move(mapping_);
        connectedDevice_.store(0);
        connectedInode_.store(0);
    }
    handoff_.Clear();
    if (old) {
        rf_set_driver_connected(old->Memory(), false);
    }
    resampler_.Reset();
    // `old` unmaps with its locally captured length.
}

void UniversalAudioHandler::RefreshIfReplaced(int dirfd, uid_t owner) {
    handoff_.Reap();
    const ino_t connected = connectedInode_.load();
    if (connected == 0 || handoff_.HasPending()) return;

    const MappingIdentity current = CurrentMappingIdentity(dirfd, owner, deviceUID_);
    // Missing or untrusted file: the heartbeat check removes the device instead.
    if (!current) return;
    if (current.inode == connected && current.device == connectedDevice_.load()) return;

    OpenResult result;
    auto mapping = SharedAudioMapping::Open(dirfd, owner, deviceUID_, true, &result);
    if (!mapping) {
        if (result.layout != RF_LAYOUT_OK) {
            RF_LOG_ERROR("Replacement mapping rejected: %{public}s", rf_layout_status_string(result.layout));
        }
        return;
    }
    if (handoff_.Offer(std::move(mapping))) {
        RF_LOG_INFO("Host replaced shared memory; handing the new mapping to the IO thread");
    }
}

// IO thread: adopt a mapping prepared by the control thread. No allocation, no
// unmapping, and no blocking: the lock is only taken if it is free, and the old
// mapping is destroyed later by RefreshIfReplaced().
void UniversalAudioHandler::ApplyPendingMapping() {
    if (!handoff_.HasPending()) return;
    std::unique_lock<std::mutex> lock(mappingMutex_, std::try_to_lock);
    if (!lock.owns_lock()) return;
    SharedAudioMapping* next = handoff_.TakePending();
    if (!next) return;

    SharedAudioMapping* previous = mapping_.release();
    mapping_.reset(next);
    connectedDevice_.store(next->Identity().device);
    connectedInode_.store(next->Identity().inode);
    RFSharedAudio* mem = next->Memory();
    rf_set_driver_connected(mem, true);
    rf_store_volume_scalar(mem, volume_.load());
    rf_store_mute_state(mem, muted_.load());
    lock.unlock();

    if (previous) {
        rf_set_driver_connected(previous->Memory(), false);
        handoff_.Retire(previous);
    }
    resampler_.Reset();
    hasLastTimestamp_ = false;

    // Re-prefill from the buffer sized for the previous ring; a larger new ring
    // simply gets a smaller cushion.
    const size_t frames = std::min<size_t>(next->Layout().capacity_frames / 2, silence_.size() / 2);
    rf_ring_write(mem, &next->Layout(), silence_.data(), frames * 2);
}

void UniversalAudioHandler::PublishVolume(Float32 scalar) {
    const float sanitized = rf_sanitize_volume(scalar);
    volume_.store(sanitized);
    std::lock_guard<std::mutex> lock(mappingMutex_);
    if (mapping_) rf_store_volume_scalar(mapping_->Memory(), sanitized);
}

void UniversalAudioHandler::PublishMute(bool muted) {
    muted_.store(muted);
    std::lock_guard<std::mutex> lock(mappingMutex_);
    if (mapping_) rf_store_mute_state(mapping_->Memory(), muted);
}

void UniversalAudioHandler::OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream, Float64 zeroTimestamp,
                                               Float64 timestamp, const void* bytes, UInt32 bytesCount) {
    (void)zeroTimestamp;
    ApplyPendingMapping();
    SharedAudioMapping* mapping = mapping_.get();
    if (!mapping) return;
    rf_update_driver_heartbeat(mapping->Memory());

    const AudioStreamBasicDescription fmt = stream->GetPhysicalFormat();
    const int64_t converted = ConvertToStereoFloat(fmt, bytes, bytesCount, interleaved_.data(), interleaved_.size());
    if (converted <= 0) {
        droppedWrites_.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    const uint32_t frameCount = static_cast<uint32_t>(converted);

    // Compensate timestamp gaps/overlaps so the host sees a continuous timeline.
    uint32_t skipFrames = 0;
    uint32_t silenceFrames = 0;
    if (hasLastTimestamp_) {
        const double delta = timestamp - lastTimestampEnd_;
        if (delta > 0.5) {
            silenceFrames = static_cast<uint32_t>(std::min<double>(delta, silence_.size() / 2));
        } else if (delta < -0.5) {
            skipFrames = static_cast<uint32_t>(std::min<double>(-delta, frameCount));
        }
    }
    hasLastTimestamp_ = true;
    lastTimestampEnd_ = timestamp + frameCount;

    if (silenceFrames > 0) {
        WriteRing(silence_.data(), silenceFrames, fmt.mSampleRate);
    }
    if (frameCount > skipFrames) {
        WriteRing(interleaved_.data() + skipFrames * 2, frameCount - skipFrames, fmt.mSampleRate);
    }
}

void UniversalAudioHandler::WriteRing(const float* input, uint32_t frames, double inputRate) {
    RFSharedAudio* mem = mapping_->Memory();
    const RFAudioLayout& layout = mapping_->Layout();
    const double ringRate = layout.sample_rate;

    if (inputRate != ringRate) {
        WriteResampled(input, frames, inputRate, ringRate);
        return;
    }

    // Small adaptive rate correction keeps producer and consumer clocks centered.
    const int64_t capacity = layout.capacity_frames;
    const int64_t target = capacity / kFillTargetDivisor;
    const int64_t error = target - static_cast<int64_t>(rf_ring_fill(mem, &layout));
    const int64_t deadband = std::max<int64_t>(1, capacity * kFillDeadbandPercent / 100);
    if (std::llabs(error) <= deadband) {
        rf_ring_write(mem, &layout, input, static_cast<size_t>(frames) * 2);
        return;
    }
    const double normalized = static_cast<double>(error) / std::max<int64_t>(1, target);
    const double ppm = std::clamp(normalized * kMaxDriftAdjustPpm, -kMaxDriftAdjustPpm, kMaxDriftAdjustPpm);
    WriteResampled(input, frames, inputRate, inputRate * (1.0 + ppm / 1'000'000.0));
}

void UniversalAudioHandler::WriteResampled(const float* input, uint32_t frames, double inputRate, double outputRate) {
    if (inputRate <= 0.0 || outputRate <= 0.0) return;
    const double expected = std::ceil(frames * outputRate / inputRate) + 10.0;
    const size_t capacity = resampled_.size() / 2;
    const uint32_t outputCapacity = static_cast<uint32_t>(std::min<double>(expected, capacity));
    const uint32_t produced =
        resampler_.Process(input, frames, inputRate, outputRate, resampled_.data(), outputCapacity);
    if (produced > 0) {
        rf_ring_write(mapping_->Memory(), &mapping_->Layout(), resampled_.data(), static_cast<size_t>(produced) * 2);
    }
}

OSStatus SoundBridgeVolumeControl::SetRawValueImpl(SInt32 value) {
    OSStatus status = aspl::VolumeControl::SetRawValueImpl(value);
    if (status == kAudioHardwareNoError) {
        if (auto handler = handler_.lock()) handler->PublishVolume(GetScalarValue());
    }
    return status;
}

OSStatus SoundBridgeMuteControl::SetIsMutedImpl(bool isMuted) {
    OSStatus status = aspl::MuteControl::SetIsMutedImpl(isMuted);
    if (status == kAudioHardwareNoError) {
        if (auto handler = handler_.lock()) handler->PublishMute(isMuted);
    }
    return status;
}

} // namespace soundbridge
