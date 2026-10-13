#include "StreamConversion.hpp"
#include "test_harness.h"
#include "test_support.h"

#include <vector>

using namespace soundbridge;

namespace {

AudioStreamBasicDescription Format(UInt32 flags, UInt32 bits, UInt32 channels, UInt32 bytesPerSample) {
    AudioStreamBasicDescription fmt{};
    fmt.mSampleRate = 48000;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = flags | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = bits;
    fmt.mChannelsPerFrame = channels;
    fmt.mBytesPerFrame = bytesPerSample * channels;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = fmt.mBytesPerFrame;
    return fmt;
}

const UInt32 kFloat = kAudioFormatFlagIsFloat;
const UInt32 kInt = kAudioFormatFlagIsSignedInteger;

} // namespace

SB_TEST(conversion_float32_stereo_mono_and_multichannel) {
    std::vector<float> out(16);
    float stereo[] = {0.1f, -0.2f, 0.3f, -0.4f};
    CHECK_EQ(ConvertToStereoFloat(Format(kFloat, 32, 2, 4), stereo, sizeof(stereo), out.data(), out.size()), 2);
    CHECK_EQ(out[2], 0.3f);
    CHECK_EQ(out[3], -0.4f);

    float mono[] = {0.5f, -0.5f};
    CHECK_EQ(ConvertToStereoFloat(Format(kFloat, 32, 1, 4), mono, sizeof(mono), out.data(), out.size()), 2);
    CHECK_EQ(out[0], 0.5f);
    CHECK_EQ(out[1], 0.5f);
    CHECK_EQ(out[3], -0.5f);

    float six[12] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
    CHECK_EQ(ConvertToStereoFloat(Format(kFloat, 32, 6, 4), six, sizeof(six), out.data(), out.size()), 2);
    CHECK_EQ(out[2], 7.0f);
    CHECK_EQ(out[3], 8.0f);

    double f64[] = {0.25, -0.75};
    CHECK_EQ(ConvertToStereoFloat(Format(kFloat, 64, 2, 8), f64, sizeof(f64), out.data(), out.size()), 1);
    CHECK_EQ(out[1], -0.75f);
}

SB_TEST(conversion_integer_scaling) {
    std::vector<float> out(4);
    int16_t i16[] = {INT16_MIN, INT16_MAX};
    CHECK_EQ(ConvertToStereoFloat(Format(kInt, 16, 2, 2), i16, sizeof(i16), out.data(), out.size()), 1);
    CHECK_EQ(out[0], -1.0f);
    CHECK(out[1] > 0.9999f && out[1] < 1.0f);

    uint8_t i24[] = {0x00, 0x00, 0x80, 0xff, 0xff, 0x7f}; // min, max
    CHECK_EQ(ConvertToStereoFloat(Format(kInt, 24, 2, 3), i24, sizeof(i24), out.data(), out.size()), 1);
    CHECK_EQ(out[0], -1.0f);
    CHECK(out[1] > 0.9999f && out[1] < 1.0f);

    int32_t i32[] = {INT32_MIN, 0};
    CHECK_EQ(ConvertToStereoFloat(Format(kInt, 32, 2, 4), i32, sizeof(i32), out.data(), out.size()), 1);
    CHECK_EQ(out[0], -1.0f);
    CHECK_EQ(out[1], 0.0f);
}

SB_TEST(conversion_rejects_unsupported_or_inconsistent_formats) {
    std::vector<float> out(64);
    float data[8] = {};
    auto rejects = [&](AudioStreamBasicDescription fmt) {
        return ConvertToStereoFloat(fmt, data, sizeof(data), out.data(), out.size()) == -1;
    };
    CHECK(rejects(Format(kFloat | kAudioFormatFlagIsNonInterleaved, 32, 2, 4)));
    CHECK(rejects(Format(kFloat | kAudioFormatFlagIsBigEndian, 32, 2, 4)));
    CHECK(rejects(Format(0, 16, 2, 2)));  // unsigned integer
    CHECK(rejects(Format(kInt, 20, 2, 3)));
    CHECK(rejects(Format(kFloat, 16, 2, 2)));
    CHECK(rejects(Format(kFloat, 32, 0, 4)));
    CHECK(rejects(Format(kFloat, 32, kMaxStreamChannels + 1, 4)));
    auto mismatched = Format(kFloat, 32, 2, 4);
    mismatched.mBytesPerFrame = 4; // claims 1 sample per frame for 2 channels
    CHECK(rejects(mismatched));
    auto notPCM = Format(kFloat, 32, 2, 4);
    notPCM.mFormatID = kAudioFormatAppleLossless;
    CHECK(rejects(notPCM));
    CHECK_EQ(ConvertToStereoFloat(Format(kFloat, 32, 2, 4), nullptr, 8, out.data(), out.size()), -1);
}

SB_TEST(conversion_respects_output_capacity_and_alignment) {
    std::vector<float> in(1000 * 2, 0.5f);
    ExactBuffer outBuffer(2 * sizeof(float) * 10);
    auto* out = static_cast<float*>(static_cast<void*>(outBuffer.data));
    CHECK_EQ(ConvertToStereoFloat(Format(kFloat, 32, 2, 4), in.data(), 1000 * 8, out, 20), -1);
    CHECK_EQ(ConvertToStereoFloat(Format(kFloat, 32, 2, 4), in.data(), 10 * 8 + 5, out, 20), 10); // partial frame ignored

    // Misaligned source buffer: conversion must not assume float alignment.
    std::vector<uint8_t> raw(1 + 8 * 4);
    float value = 0.75f;
    for (int i = 0; i < 8; i++) std::memcpy(raw.data() + 1 + i * 4, &value, 4);
    CHECK_EQ(ConvertToStereoFloat(Format(kFloat, 32, 2, 4), raw.data() + 1, 32, out, 20), 4);
    CHECK_EQ(out[7], 0.75f);
}

SB_TEST(resampler_bounds_and_ratio) {
    StereoResampler resampler;
    std::vector<float> in(480 * 2, 0.25f);
    std::vector<float> out(2000 * 2);
    uint32_t produced = resampler.Process(in.data(), 480, 48000, 96000, out.data(), 2000);
    CHECK(produced >= 958 && produced <= 961);
    produced = resampler.Process(in.data(), 480, 48000, 96000, out.data(), 100);
    CHECK_EQ(produced, 100u);
    resampler.Reset();
    CHECK_EQ(resampler.Process(in.data(), 480, 48000, 48000, out.data(), 2000), 480u);
    CHECK_EQ(out[959], 0.25f);
    CHECK_EQ(resampler.Process(in.data(), 0, 48000, 48000, out.data(), 2000), 0u);
    CHECK_EQ(resampler.Process(in.data(), 480, 0, 48000, out.data(), 2000), 0u);
}
