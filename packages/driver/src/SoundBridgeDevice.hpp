#pragma once

#include <aspl/Device.hpp>

#include <mach/mach_time.h>

namespace soundbridge {

// Device subclass with a GetZeroTimeStamp that computes elapsed periods from an
// anchor. libASPL's default only increments the period counter by one per
// call, so a late HAL call makes the clock fall behind permanently, which
// Safari's Web Audio drift compensation hears as stutter.
class SoundBridgeDevice : public aspl::Device {
public:
    SoundBridgeDevice(std::shared_ptr<aspl::Context> context, const aspl::DeviceParameters& params)
        : aspl::Device(context, params) {
        // mach_timebase_info is a syscall; the ratio is a hardware constant.
        struct mach_timebase_info tb = {};
        mach_timebase_info(&tb);
        // numer == 0 means failure; 1e9 (1 ns per tick) is correct for Apple Silicon.
        hostClockFreq_ = (tb.numer > 0) ? Float64(tb.denom) / Float64(tb.numer) * 1.0e9 : 1.0e9;
    }

protected:
    // StartIOImpl is intentionally not overridden: the anchor is set lazily once
    // and never reset, so the clock stays continuous across IO start/stop cycles.
    OSStatus GetZeroTimeStampImpl(UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime,
                                  UInt64* outSeed) override {
        (void)clientID;
        const UInt64 now = mach_absolute_time();
        if (anchorTime_ == 0) {
            anchorTime_ = now;
            periodCounter_ = 0;
        }

        Float64 sampleRate = GetNominalSampleRate();
        if (sampleRate <= 0) {
            sampleRate = (lastSampleRate_ > 0) ? lastSampleRate_ : 48000.0;
        }
        if (hostTicksPerFrame_ <= 0) {
            hostTicksPerFrame_ = hostClockFreq_ / sampleRate;
            lastSampleRate_ = sampleRate;
        } else if (sampleRate != lastSampleRate_) {
            // Re-anchor so outSampleTime stays monotonic; bump seed so HAL re-syncs.
            anchorTime_ = now;
            periodCounter_ = 0;
            hostTicksPerFrame_ = hostClockFreq_ / sampleRate;
            lastSampleRate_ = sampleRate;
            ++clockSeed_;
        }

        const Float64 period = GetZeroTimeStampPeriod();
        if (period <= 0 || hostTicksPerFrame_ <= 0) {
            *outSampleTime = 0;
            *outHostTime = anchorTime_;
            *outSeed = clockSeed_;
            return kAudioHardwareNoError;
        }
        const Float64 ticksPerPeriod = hostTicksPerFrame_ * period;
        if (ticksPerPeriod > 0 && now >= anchorTime_) {
            periodCounter_ = static_cast<UInt64>(Float64(now - anchorTime_) / ticksPerPeriod);
        }

        *outSampleTime = periodCounter_ * period;
        *outHostTime = anchorTime_ + UInt64(Float64(periodCounter_) * ticksPerPeriod);
        *outSeed = clockSeed_;
        return kAudioHardwareNoError;
    }

private:
    // Serialized by libASPL's Device::ioMutex_, which GetZeroTimeStamp() holds.
    UInt64 anchorTime_ = 0;
    UInt64 periodCounter_ = 0;
    Float64 hostTicksPerFrame_ = 0;
    Float64 lastSampleRate_ = 0;
    Float64 hostClockFreq_ = 0;
    UInt64 clockSeed_ = 1;
};

} // namespace soundbridge
