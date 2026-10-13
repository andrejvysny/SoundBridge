#pragma once

#include "RFSecureIPC.h"
#include "RFSharedAudio.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>

// Exact-size heap allocation so AddressSanitizer flags any byte past `size`.
struct ExactBuffer {
    explicit ExactBuffer(size_t n) : size(n), data(static_cast<uint8_t*>(std::calloc(1, n ? n : 1))) {}
    ~ExactBuffer() { std::free(data); }
    ExactBuffer(const ExactBuffer&) = delete;
    ExactBuffer& operator=(const ExactBuffer&) = delete;

    size_t size;
    uint8_t* data;
};

inline void HashOf(const std::string& uid, uint8_t out[RF_UID_HASH_SIZE]) { rf_uid_hash(uid.data(), uid.size(), out); }

struct TestRing {
    explicit TestRing(uint32_t rate = 48000, uint32_t durationMs = 100, const std::string& uid = "test-device")
        : capacity(rf_frames_for_duration(rate, durationMs)), buffer(rf_shared_audio_size(capacity)) {
        HashOf(uid, hash);
        initialized = rf_shared_audio_init(Mem(), buffer.size, rate, durationMs, hash);
        status = rf_validate_layout(Mem(), buffer.size, hash, &layout);
    }

    RFSharedAudio* Mem() { return static_cast<RFSharedAudio*>(static_cast<void*>(buffer.data)); }

    void SetIndices(uint64_t write, uint64_t read) {
        RF_ATOMIC_STORE(&Mem()->write_index, write);
        RF_ATOMIC_STORE(&Mem()->read_index, read);
    }
    uint64_t WriteIndex() { return RF_ATOMIC_LOAD(&Mem()->write_index); }
    uint64_t ReadIndex() { return RF_ATOMIC_LOAD(&Mem()->read_index); }

    uint32_t capacity;
    ExactBuffer buffer;
    uint8_t hash[RF_UID_HASH_SIZE];
    bool initialized = false;
    RFLayoutStatus status = RF_LAYOUT_ERR_NULL;
    RFAudioLayout layout{};
};

inline std::mt19937_64& Rng() {
    static std::mt19937_64 rng(0x5b5b5b5bULL);
    return rng;
}
