#pragma once

// Conversion of HAL mixed-output buffers into the fixed stereo float32
// transport. Header-only for the native test harness.

#include <CoreAudio/CoreAudioTypes.h>

#include <algorithm>
#include <cstdint>
#include <cstring>

namespace soundbridge {

constexpr UInt32 kMaxStreamChannels = 16;

namespace detail {

inline float ReadSample(const uint8_t* src, UInt32 sampleBytes, bool isFloat) {
    if (isFloat) {
        if (sampleBytes == 4) {
            float v;
            std::memcpy(&v, src, sizeof(v));
            return v;
        }
        double v;
        std::memcpy(&v, src, sizeof(v));
        return static_cast<float>(v);
    }
    switch (sampleBytes) {
        case 2: {
            int16_t v;
            std::memcpy(&v, src, sizeof(v));
            return static_cast<float>(v) / 32768.0f;
        }
        case 3: {
            int32_t v = static_cast<int32_t>(src[0]) | (static_cast<int32_t>(src[1]) << 8) |
                        (static_cast<int32_t>(src[2]) << 16);
            if (v & 0x800000) v -= 0x1000000;
            return static_cast<float>(v) / 8388608.0f;
        }
        default: {
            int32_t v;
            std::memcpy(&v, src, sizeof(v));
            return static_cast<float>(static_cast<double>(v) / 2147483648.0);
        }
    }
}

} // namespace detail

// Returns bytes per sample for a supported interleaved little-endian linear PCM
// format, or 0 if the description is unsupported or internally inconsistent.
inline UInt32 SupportedSampleBytes(const AudioStreamBasicDescription& fmt) {
    if (fmt.mFormatID != kAudioFormatLinearPCM) return 0;
    if (fmt.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)) return 0;
    if (fmt.mChannelsPerFrame == 0 || fmt.mChannelsPerFrame > kMaxStreamChannels) return 0;

    UInt32 sampleBytes = 0;
    if (fmt.mFormatFlags & kAudioFormatFlagIsFloat) {
        if (fmt.mBitsPerChannel == 32) sampleBytes = 4;
        if (fmt.mBitsPerChannel == 64) sampleBytes = 8;
    } else if (fmt.mFormatFlags & kAudioFormatFlagIsSignedInteger) {
        if (fmt.mBitsPerChannel == 16) sampleBytes = 2;
        if (fmt.mBitsPerChannel == 24) sampleBytes = 3;
        if (fmt.mBitsPerChannel == 32) sampleBytes = 4;
    }
    if (sampleBytes == 0 || fmt.mBytesPerFrame != sampleBytes * fmt.mChannelsPerFrame) return 0;
    return sampleBytes;
}

// Converts `bytesCount` bytes of `fmt` audio into interleaved stereo float32.
// Mono is duplicated, extra channels are ignored. Returns frames written, or -1
// if the format is unsupported or `output` cannot hold the result.
inline int64_t ConvertToStereoFloat(const AudioStreamBasicDescription& fmt, const void* bytes, UInt32 bytesCount,
                                    float* output, size_t outputCapacitySamples) {
    const UInt32 sampleBytes = SupportedSampleBytes(fmt);
    if (sampleBytes == 0 || !bytes || !output) return -1;

    const UInt32 frameBytes = fmt.mBytesPerFrame;
    const uint64_t frames = bytesCount / frameBytes;
    if (frames * 2 > outputCapacitySamples) return -1;

    const bool isFloat = (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const UInt32 rightChannel = fmt.mChannelsPerFrame > 1 ? 1 : 0;
    const auto* src = static_cast<const uint8_t*>(bytes);
    for (uint64_t frame = 0; frame < frames; frame++) {
        const uint8_t* frameStart = src + frame * frameBytes;
        output[frame * 2] = detail::ReadSample(frameStart, sampleBytes, isFloat);
        output[frame * 2 + 1] = detail::ReadSample(frameStart + rightChannel * sampleBytes, sampleBytes, isFloat);
    }
    return static_cast<int64_t>(frames);
}

// Linear-interpolation stereo resampler with a carried fractional position.
class StereoResampler {
public:
    void Reset() { position_ = 0.0; }

    // Returns output frames produced (never more than outputCapacityFrames).
    uint32_t Process(const float* input, uint32_t inputFrames, double inputRate, double outputRate, float* output,
                     uint32_t outputCapacityFrames) {
        if (inputFrames == 0 || inputRate <= 0.0 || outputRate <= 0.0) return 0;
        const double ratio = inputRate / outputRate;
        uint32_t produced = 0;
        while (produced < outputCapacityFrames && position_ < inputFrames) {
            const uint32_t idx0 = static_cast<uint32_t>(position_);
            const uint32_t idx1 = std::min(idx0 + 1, inputFrames - 1);
            const float frac = static_cast<float>(position_ - idx0);
            for (uint32_t ch = 0; ch < 2; ch++) {
                const float s0 = input[idx0 * 2 + ch];
                const float s1 = input[idx1 * 2 + ch];
                output[produced * 2 + ch] = s0 + frac * (s1 - s0);
            }
            produced++;
            position_ += ratio;
        }
        position_ -= inputFrames;
        if (position_ < 0.0) position_ = 0.0;
        return produced;
    }

private:
    double position_ = 0.0;
};

} // namespace soundbridge
