#include "test_harness.h"
#include "test_support.h"

#include <functional>
#include <vector>

SB_TEST(layout_valid_for_all_rates_and_durations) {
    for (uint32_t rate : RF_SUPPORTED_SAMPLE_RATES) {
        for (uint32_t ms : {RF_RING_DURATION_MS_MIN, 50u, RF_RING_DURATION_MS_MAX}) {
            TestRing ring(rate, ms);
            CHECK(ring.initialized);
            CHECK_EQ(ring.status, RF_LAYOUT_OK);
            CHECK_EQ(ring.layout.capacity_frames, rf_frames_for_duration(rate, ms));
            CHECK_EQ(ring.layout.mapping_length, ring.buffer.size);
            CHECK_EQ(ring.layout.channels, RF_TRANSPORT_CHANNELS);
        }
    }
}

SB_TEST(layout_size_bounds) {
    CHECK_EQ(rf_shared_audio_size(0), 0u);
    CHECK_EQ(rf_shared_audio_size(RF_RING_CAPACITY_MAX_FRAMES + 1), 0u);
    CHECK_EQ(rf_shared_audio_size(UINT32_MAX), 0u);
    CHECK_EQ(rf_shared_audio_size(1), RF_AUDIO_HEADER_SIZE + 8u);
    CHECK_EQ(rf_shared_audio_max_size(), RF_AUDIO_HEADER_SIZE + RF_RING_CAPACITY_MAX_FRAMES * 8u);
    CHECK_EQ(rf_frames_for_duration(RF_MAX_SAMPLE_RATE, RF_RING_DURATION_MS_MAX), RF_RING_CAPACITY_MAX_FRAMES);
}

SB_TEST(layout_init_rejects_bad_parameters) {
    uint8_t hash[RF_UID_HASH_SIZE] = {};
    ExactBuffer buffer(rf_shared_audio_size(4800));
    auto* mem = static_cast<RFSharedAudio*>(static_cast<void*>(buffer.data));
    CHECK(rf_shared_audio_init(mem, buffer.size, 48000, 100, hash));
    CHECK(!rf_shared_audio_init(mem, buffer.size + 1, 48000, 100, hash));
    CHECK(!rf_shared_audio_init(mem, buffer.size - 1, 48000, 100, hash));
    CHECK(!rf_shared_audio_init(mem, buffer.size, 12345, 100, hash));
    CHECK(!rf_shared_audio_init(mem, buffer.size, 48000, 19, hash));
    CHECK(!rf_shared_audio_init(mem, buffer.size, 48000, 101, hash));
    CHECK(!rf_shared_audio_init(mem, buffer.size, 48000, 100, nullptr));
    CHECK(!rf_shared_audio_init(nullptr, buffer.size, 48000, 100, hash));
}

static void ExpectCorruption(const std::function<void(RFSharedAudio*)>& corrupt, RFLayoutStatus expected) {
    TestRing ring;
    corrupt(ring.Mem());
    RFAudioLayout layout{};
    CHECK_EQ(rf_validate_layout(ring.Mem(), ring.buffer.size, ring.hash, &layout), expected);
}

SB_TEST(layout_rejects_each_corrupted_field) {
    ExpectCorruption([](RFSharedAudio* m) { m->magic = 0; }, RF_LAYOUT_ERR_MAGIC);
    ExpectCorruption([](RFSharedAudio* m) { m->protocol_version = 0x00020000; }, RF_LAYOUT_ERR_VERSION);
    ExpectCorruption([](RFSharedAudio* m) { m->header_size = 512; }, RF_LAYOUT_ERR_HEADER_SIZE);
    ExpectCorruption([](RFSharedAudio* m) { m->sample_rate = 0; }, RF_LAYOUT_ERR_SAMPLE_RATE);
    ExpectCorruption([](RFSharedAudio* m) { m->sample_rate = 44000; }, RF_LAYOUT_ERR_SAMPLE_RATE);
    ExpectCorruption([](RFSharedAudio* m) { m->channels = 0; }, RF_LAYOUT_ERR_FORMAT);
    ExpectCorruption([](RFSharedAudio* m) { m->channels = 8; }, RF_LAYOUT_ERR_FORMAT);
    ExpectCorruption([](RFSharedAudio* m) { m->format = 3; }, RF_LAYOUT_ERR_FORMAT);
    ExpectCorruption([](RFSharedAudio* m) { m->bytes_per_sample = 8; }, RF_LAYOUT_ERR_FORMAT);
    ExpectCorruption([](RFSharedAudio* m) { m->bytes_per_frame = 16; }, RF_LAYOUT_ERR_FORMAT);
    ExpectCorruption([](RFSharedAudio* m) { m->ring_duration_ms = 0; }, RF_LAYOUT_ERR_DURATION);
    ExpectCorruption([](RFSharedAudio* m) { m->ring_duration_ms = 1000; }, RF_LAYOUT_ERR_DURATION);
    ExpectCorruption([](RFSharedAudio* m) { m->ring_capacity_frames = 0; }, RF_LAYOUT_ERR_CAPACITY);
    ExpectCorruption([](RFSharedAudio* m) { m->ring_capacity_frames += 1; }, RF_LAYOUT_ERR_CAPACITY);
    ExpectCorruption([](RFSharedAudio* m) { m->ring_capacity_frames = UINT32_MAX; }, RF_LAYOUT_ERR_CAPACITY);
    // Consistent-looking geometry that claims more storage than was mapped.
    ExpectCorruption(
        [](RFSharedAudio* m) {
            m->sample_rate = 192000;
            m->ring_capacity_frames = rf_frames_for_duration(192000, 100);
        },
        RF_LAYOUT_ERR_SIZE_MISMATCH);
    ExpectCorruption([](RFSharedAudio* m) { m->device_uid_hash[5] ^= 0xff; }, RF_LAYOUT_ERR_DEVICE);
}

SB_TEST(layout_rejects_mapping_length_mismatch) {
    TestRing ring;
    RFAudioLayout layout{};
    CHECK_EQ(rf_validate_layout(ring.Mem(), 0, ring.hash, &layout), RF_LAYOUT_ERR_TOO_SMALL);
    CHECK_EQ(rf_validate_layout(ring.Mem(), RF_AUDIO_HEADER_SIZE - 1, ring.hash, &layout), RF_LAYOUT_ERR_TOO_SMALL);
    CHECK_EQ(rf_validate_layout(ring.Mem(), RF_AUDIO_HEADER_SIZE, ring.hash, &layout), RF_LAYOUT_ERR_SIZE_MISMATCH);
    CHECK_EQ(rf_validate_layout(ring.Mem(), ring.buffer.size - 8, ring.hash, &layout), RF_LAYOUT_ERR_SIZE_MISMATCH);
    CHECK_EQ(rf_validate_layout(nullptr, ring.buffer.size, ring.hash, &layout), RF_LAYOUT_ERR_NULL);
    CHECK_EQ(rf_validate_layout(ring.Mem(), ring.buffer.size, nullptr, &layout), RF_LAYOUT_OK);
}

// Random headers in exact-size allocations: validation must never accept a
// geometry that does not fit, and accepted layouts must be safe to use.
SB_TEST(layout_fuzz_random_headers) {
    auto& rng = Rng();
    int accepted = 0;
    for (int iteration = 0; iteration < 20000; iteration++) {
        const bool nearlyValid = rng() % 2;
        const uint32_t rate = RF_SUPPORTED_SAMPLE_RATES[rng() % RF_NUM_SAMPLE_RATES];
        const uint32_t ms = 20 + static_cast<uint32_t>(rng() % 81);
        const uint32_t capacity = rf_frames_for_duration(rate, ms);
        size_t length = RF_AUDIO_HEADER_SIZE + rng() % 40000;
        if (nearlyValid) {
            length = rf_shared_audio_size(capacity);
            if (rng() % 4 == 0) length += rng() % 16; // off-by-some mapping sizes
        }
        ExactBuffer buffer(length);
        for (size_t i = 0; i < RF_AUDIO_HEADER_SIZE; i++) buffer.data[i] = static_cast<uint8_t>(rng());
        auto* mem = static_cast<RFSharedAudio*>(static_cast<void*>(buffer.data));
        if (nearlyValid) {
            mem->magic = RF_AUDIO_MAGIC;
            mem->protocol_version = RF_AUDIO_PROTOCOL_VERSION;
            mem->header_size = RF_AUDIO_HEADER_SIZE;
            mem->sample_rate = rate;
            mem->channels = (rng() % 8) ? 2 : static_cast<uint32_t>(rng());
            mem->format = RF_FORMAT_FLOAT32;
            mem->bytes_per_sample = 4;
            mem->bytes_per_frame = 8;
            mem->ring_duration_ms = ms;
            mem->ring_capacity_frames = (rng() % 8) ? capacity : static_cast<uint32_t>(rng());
        }
        RFAudioLayout layout{};
        if (rf_validate_layout(mem, length, nullptr, &layout) != RF_LAYOUT_OK) continue;
        accepted++;
        CHECK(layout.capacity_frames > 0 && layout.capacity_frames <= RF_RING_CAPACITY_MAX_FRAMES);
        CHECK_EQ(layout.mapping_length, length);
        CHECK_EQ(length, RF_AUDIO_HEADER_SIZE + static_cast<size_t>(layout.capacity_frames) * 8);
        std::vector<float> io(static_cast<size_t>(rng() % 30000) * 2 + 1);
        RF_ATOMIC_STORE(&mem->write_index, rng());
        RF_ATOMIC_STORE(&mem->read_index, (rng() % 2) ? rng() : RF_ATOMIC_LOAD(&mem->write_index) - rng() % 30000);
        rf_ring_write(mem, &layout, io.data(), io.size());
        rf_ring_read(mem, &layout, io.data(), io.size());
    }
    CHECK(accepted > 1000);
}
