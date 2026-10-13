#include "test_harness.h"
#include "test_support.h"

#include <cmath>
#include <limits>
#include <vector>

static std::vector<float> Ramp(size_t frames, float start) {
    std::vector<float> samples(frames * 2);
    for (size_t i = 0; i < frames; i++) {
        samples[i * 2] = start + static_cast<float>(i);
        samples[i * 2 + 1] = -(start + static_cast<float>(i));
    }
    return samples;
}

SB_TEST(ring_roundtrip_and_wraparound) {
    TestRing ring(44100, 20); // 882 frames
    CHECK_EQ(ring.status, RF_LAYOUT_OK);
    std::vector<float> out(700 * 2);
    for (int round = 0; round < 10; round++) {
        auto in = Ramp(700, static_cast<float>(round * 1000));
        CHECK_EQ(rf_ring_write(ring.Mem(), &ring.layout, in.data(), in.size()), 700u);
        CHECK_EQ(rf_ring_read(ring.Mem(), &ring.layout, out.data(), out.size()), 700u);
        CHECK(out == in);
    }
    CHECK_EQ(ring.WriteIndex(), 7000u);
    CHECK_EQ(ring.ReadIndex(), 7000u);
}

SB_TEST(ring_overflow_drops_newest_and_never_moves_read_index) {
    TestRing ring(44100, 20);
    auto in = Ramp(1000, 1.0f);
    ring.SetIndices(0, 0);
    CHECK_EQ(rf_ring_write(ring.Mem(), &ring.layout, in.data(), in.size()), ring.capacity);
    CHECK_EQ(ring.ReadIndex(), 0u);
    CHECK_EQ(rf_get_overrun_count(ring.Mem()), 1u);
    CHECK_EQ(rf_ring_write(ring.Mem(), &ring.layout, in.data(), in.size()), 0u);
    CHECK_EQ(ring.ReadIndex(), 0u);

    std::vector<float> out(ring.capacity * 2);
    CHECK_EQ(rf_ring_read(ring.Mem(), &ring.layout, out.data(), out.size()), ring.capacity);
    CHECK(std::equal(out.begin(), out.end(), in.begin()));
}

SB_TEST(ring_underrun_zero_fills_and_never_moves_write_index) {
    TestRing ring;
    auto in = Ramp(10, 5.0f);
    rf_ring_write(ring.Mem(), &ring.layout, in.data(), in.size());
    std::vector<float> out(64 * 2, 99.0f);
    CHECK_EQ(rf_ring_read(ring.Mem(), &ring.layout, out.data(), out.size()), 10u);
    CHECK(std::equal(in.begin(), in.end(), out.begin()));
    for (size_t i = in.size(); i < out.size(); i++) CHECK_EQ(out[i], 0.0f);
    CHECK_EQ(rf_get_underrun_count(ring.Mem()), 1u);
    CHECK_EQ(ring.WriteIndex(), 10u);
}

SB_TEST(ring_odd_sample_counts_use_whole_frames_only) {
    TestRing ring;
    std::vector<float> in = {1, 2, 3, 4, 5};
    CHECK_EQ(rf_ring_write(ring.Mem(), &ring.layout, in.data(), in.size()), 2u);
    ExactBuffer out(5 * sizeof(float));
    auto* samples = static_cast<float*>(static_cast<void*>(out.data));
    CHECK_EQ(rf_ring_read(ring.Mem(), &ring.layout, samples, 5), 2u);
    CHECK_EQ(samples[3], 4.0f);
    CHECK_EQ(samples[4], 0.0f);
}

SB_TEST(ring_consumer_resyncs_on_impossible_distance) {
    TestRing ring;
    std::vector<float> out(256 * 2, 1.0f);
    for (auto [write, read] : {std::pair<uint64_t, uint64_t>{10, 20},
                               {UINT64_MAX, 0},
                               {1'000'000, 0},
                               {5, UINT64_MAX - 100000}}) {
        ring.SetIndices(write, read);
        CHECK_EQ(rf_ring_read(ring.Mem(), &ring.layout, out.data(), out.size()), 0u);
        CHECK_EQ(ring.ReadIndex(), write);
        CHECK_EQ(ring.WriteIndex(), write);
        for (float s : out) CHECK_EQ(s, 0.0f);
    }
}

SB_TEST(ring_producer_resyncs_on_impossible_distance) {
    TestRing ring;
    auto in = Ramp(16, 1.0f);
    ring.SetIndices(3, 1'000'000);
    CHECK_EQ(rf_ring_write(ring.Mem(), &ring.layout, in.data(), in.size()), 16u);
    CHECK_EQ(ring.ReadIndex(), 1'000'000u);
    CHECK_EQ(ring.WriteIndex(), 1'000'016u);
}

SB_TEST(ring_counter_wrap_near_uint64_max) {
    TestRing ring(44100, 20);
    const uint64_t base = UINT64_MAX - 5;
    ring.SetIndices(base, base);
    auto in = Ramp(20, 1.0f);
    CHECK_EQ(rf_ring_write(ring.Mem(), &ring.layout, in.data(), in.size()), 20u);
    std::vector<float> out(in.size());
    CHECK_EQ(rf_ring_read(ring.Mem(), &ring.layout, out.data(), out.size()), 20u);
    CHECK(out == in);
}

SB_TEST(ring_adversarial_indices_stay_in_bounds) {
    auto& rng = Rng();
    TestRing ring(48000, 20);
    for (int i = 0; i < 50000; i++) {
        const uint64_t base = rng();
        ring.SetIndices(base + rng() % (3 * ring.capacity), base + rng() % (3 * ring.capacity));
        if (rng() % 3 == 0) ring.SetIndices(rng(), rng());
        std::vector<float> io(rng() % (4 * ring.capacity) + 1);
        rf_ring_write(ring.Mem(), &ring.layout, io.data(), io.size());
        rf_ring_read(ring.Mem(), &ring.layout, io.data(), io.size());
        CHECK(rf_ring_fill(ring.Mem(), &ring.layout) <= ring.capacity);
    }
}

// A ring that was written while nobody consumed it must not replay that audio
// when it becomes the active device again.
SB_TEST(ring_consumer_drain_drops_stale_audio) {
    TestRing ring;
    auto stale = Ramp(120, 7.0f);
    CHECK_EQ(rf_ring_write(ring.Mem(), &ring.layout, stale.data(), stale.size()), 120u);
    CHECK_EQ(rf_ring_fill(ring.Mem(), &ring.layout), 120u);

    rf_ring_consumer_drain(ring.Mem());
    CHECK_EQ(rf_ring_fill(ring.Mem(), &ring.layout), 0u);
    CHECK_EQ(ring.WriteIndex(), 120u); // producer index untouched
    CHECK_EQ(ring.ReadIndex(), 120u);

    std::vector<float> out(8, 5.0f);
    CHECK_EQ(rf_ring_read(ring.Mem(), &ring.layout, out.data(), out.size()), 0u);
    for (float sample : out) CHECK_EQ(sample, 0.0f);

    auto fresh = Ramp(4, 1.0f);
    CHECK_EQ(rf_ring_write(ring.Mem(), &ring.layout, fresh.data(), fresh.size()), 4u);
    CHECK_EQ(rf_ring_read(ring.Mem(), &ring.layout, out.data(), out.size()), 4u);
    CHECK(std::equal(fresh.begin(), fresh.end(), out.begin()));
    rf_ring_consumer_drain(nullptr);
}

SB_TEST(ring_null_arguments_are_safe) {
    TestRing ring;
    float out[4] = {1, 1, 1, 1};
    CHECK_EQ(rf_ring_write(nullptr, &ring.layout, out, 4), 0u);
    CHECK_EQ(rf_ring_write(ring.Mem(), nullptr, out, 4), 0u);
    CHECK_EQ(rf_ring_read(nullptr, &ring.layout, out, 4), 0u);
    CHECK_EQ(out[0], 0.0f);
    RFAudioLayout empty{};
    CHECK_EQ(rf_ring_read(ring.Mem(), &empty, out, 4), 0u);
}

SB_TEST(sanitize_samples_and_volume) {
    const float inf = std::numeric_limits<float>::infinity();
    float samples[] = {0.5f, std::nanf(""), inf, -inf, 3.0f, -3.0f};
    CHECK_EQ(rf_sanitize_samples(samples, 6, 1.0f), 3u);
    CHECK_EQ(samples[0], 0.5f);
    CHECK_EQ(samples[1], 0.0f);
    CHECK_EQ(samples[2], 0.0f);
    CHECK_EQ(samples[4], 1.0f);
    CHECK_EQ(samples[5], -1.0f);

    CHECK_EQ(rf_sanitize_volume(std::nanf("")), 0.0f);
    CHECK_EQ(rf_sanitize_volume(inf), 0.0f);
    CHECK_EQ(rf_sanitize_volume(-0.5f), 0.0f);
    CHECK_EQ(rf_sanitize_volume(7.0f), 1.0f);
    CHECK_EQ(rf_sanitize_volume(0.25f), 0.25f);

    TestRing ring;
    CHECK_EQ(rf_load_volume_scalar(ring.Mem()), 0.0f); // silent until published
    RF_ATOMIC_STORE(&ring.Mem()->volume_scalar, std::nanf(""));
    CHECK_EQ(rf_load_volume_scalar(ring.Mem()), 0.0f);
    RF_ATOMIC_STORE(&ring.Mem()->volume_scalar, 1e30f);
    CHECK_EQ(rf_load_volume_scalar(ring.Mem()), 1.0f);
    RF_ATOMIC_STORE(&ring.Mem()->mute_state, 7);
    CHECK(rf_load_mute_state(ring.Mem()));
}
