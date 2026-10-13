#pragma once

#include "MappingHandoff.hpp"
#include "SharedMapping.hpp"
#include "StreamConversion.hpp"

#include <aspl/ControlRequestHandler.hpp>
#include <aspl/IORequestHandler.hpp>
#include <aspl/MuteControl.hpp>
#include <aspl/Stream.hpp>
#include <aspl/VolumeControl.hpp>
// aspl::VolumeControl holds unique_ptr<VolumeCurve>; subclasses need the complete type.
#include "VolumeCurve.hpp"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace soundbridge {

// IO/control handler for one proxy device.
//
// Threading:
//  - OnStartIO/OnStopIO/OnWriteMixedOutput are serialized by libASPL's
//    per-device IO mutex, so the IO thread may read mapping_ without locking.
//  - Volume/mute controls publish from HAL property threads and take
//    mappingMutex_, which every mapping_ replacement also holds.
class UniversalAudioHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    explicit UniversalAudioHandler(std::string deviceUID);
    ~UniversalAudioHandler() override;

    OSStatus OnStartIO() override;
    void OnStopIO() override;
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream, Float64 zeroTimestamp, Float64 timestamp,
                            const void* bytes, UInt32 bytesCount) override;

    void PublishVolume(Float32 scalar);
    void PublishMute(bool muted);

    /// Control thread: if the host replaced this device's file (restart, crash
    /// recovery, sample-rate change), prepare the new mapping for the IO thread
    /// and free any mapping the IO thread already handed back.
    void RefreshIfReplaced(int dirfd, uid_t owner);

private:
    bool Connect();
    void Disconnect();
    void ApplyPendingMapping();
    void WriteRing(const float* input, uint32_t frames, double inputRate);
    void WriteResampled(const float* input, uint32_t frames, double inputRate, double outputRate);

    const std::string deviceUID_;

    std::mutex mappingMutex_;
    std::unique_ptr<SharedAudioMapping> mapping_;
    MappingHandoff<SharedAudioMapping> handoff_;
    std::atomic<dev_t> connectedDevice_{0};
    std::atomic<ino_t> connectedInode_{0};

    std::atomic<Float32> volume_{0.0f};
    std::atomic<bool> muted_{false};
    int32_t ioClientCount_ = 0;

    StereoResampler resampler_;
    std::vector<float> interleaved_;
    std::vector<float> resampled_;
    std::vector<float> silence_;
    bool hasLastTimestamp_ = false;
    double lastTimestampEnd_ = 0.0;

    std::atomic<uint64_t> droppedWrites_{0};
};

// Volume control that mirrors changes into shared memory for the host.
class SoundBridgeVolumeControl : public aspl::VolumeControl {
public:
    using aspl::VolumeControl::VolumeControl;
    void SetHandler(std::weak_ptr<UniversalAudioHandler> handler) { handler_ = std::move(handler); }

protected:
    OSStatus SetRawValueImpl(SInt32 value) override;

private:
    std::weak_ptr<UniversalAudioHandler> handler_;
};

class SoundBridgeMuteControl : public aspl::MuteControl {
public:
    using aspl::MuteControl::MuteControl;
    void SetHandler(std::weak_ptr<UniversalAudioHandler> handler) { handler_ = std::move(handler); }

protected:
    OSStatus SetIsMutedImpl(bool isMuted) override;

private:
    std::weak_ptr<UniversalAudioHandler> handler_;
};

// Resolve the active console user's session directory. Returns an invalid fd
// when nobody is logged in or the directory is missing/untrusted.
UniqueFd OpenConsoleSessionDir(uid_t* outOwner);

} // namespace soundbridge
