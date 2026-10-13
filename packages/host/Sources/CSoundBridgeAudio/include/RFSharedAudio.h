#ifndef RF_SHARED_AUDIO_H
#define RF_SHARED_AUDIO_H

/*
 * SoundBridge shared-memory protocol (driver <-> host audio, app -> host EQ).
 *
 * Identical copies live in:
 *   packages/driver/include/
 *   packages/host/Sources/CSoundBridgeAudio/include/
 *   apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/
 * `tools/check_protocol_sync.sh` enforces this.
 *
 * Trust model: every byte of a mapping is writable by the peer, so header
 * geometry is validated once into a local RFAudioLayout and never re-read.
 * Ring indices are re-read on every call and bounds-checked against that
 * local layout. Each index has exactly one writer (producer: write_index,
 * consumer: read_index).
 */

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#define RF_STATIC_ASSERT(cond, msg) static_assert(cond, msg)
#else
#define RF_STATIC_ASSERT(cond, msg) _Static_assert(cond, msg)
#endif

// <stdatomic.h> is deliberately not used: its function-like macros (atomic_load, ...)
// collide with libc++ <atomic>/<memory> before C++23. The clang builtins below
// are what those macros expand to, and work in both C and C++.
#define RF_ATOMIC_LOAD(obj) __c11_atomic_load(obj, __ATOMIC_SEQ_CST)
#define RF_ATOMIC_STORE(obj, value) __c11_atomic_store(obj, value, __ATOMIC_SEQ_CST)
#define RF_ATOMIC_ADD(obj, value) __c11_atomic_fetch_add(obj, value, __ATOMIC_SEQ_CST)

// ===== AUDIO TRANSPORT CONSTANTS =====

#define RF_AUDIO_MAGIC 0x55414253u /* "SBAU" */
#define RF_AUDIO_PROTOCOL_VERSION 0x00030000u
#define RF_AUDIO_HEADER_SIZE 256u

// The transport is fixed to interleaved stereo float32. The DSP engine is
// stereo-only, so wider layouts are rejected rather than half-supported.
typedef enum { RF_FORMAT_FLOAT32 = 0 } RFAudioFormat;

#define RF_TRANSPORT_CHANNELS 2u
#define RF_TRANSPORT_BYTES_PER_SAMPLE 4u
#define RF_TRANSPORT_BYTES_PER_FRAME 8u

static const uint32_t RF_SUPPORTED_SAMPLE_RATES[] = {44100, 48000, 88200, 96000, 176400, 192000};
#define RF_NUM_SAMPLE_RATES 6
#define RF_MAX_SAMPLE_RATE 192000u

#define RF_RING_DURATION_MS_MIN 20u
#define RF_RING_DURATION_MS_MAX 100u
#define RF_RING_DURATION_MS_DEFAULT 100u
#define RF_RING_CAPACITY_MAX_FRAMES 19200u /* RF_MAX_SAMPLE_RATE * RF_RING_DURATION_MS_MAX / 1000 */

#define RF_UID_HASH_SIZE 32u

// Largest valid volume scalar; anything else is treated as silence.
#define RF_VOLUME_MAX 1.0f

typedef struct {
    // ===== IMMUTABLE AFTER CREATION (validated once by readers) =====
    uint32_t magic;                // RF_AUDIO_MAGIC
    uint32_t protocol_version;     // RF_AUDIO_PROTOCOL_VERSION
    uint32_t header_size;          // RF_AUDIO_HEADER_SIZE
    uint32_t sample_rate;          // one of RF_SUPPORTED_SAMPLE_RATES
    uint32_t channels;             // RF_TRANSPORT_CHANNELS
    uint32_t format;               // RF_FORMAT_FLOAT32
    uint32_t bytes_per_sample;     // RF_TRANSPORT_BYTES_PER_SAMPLE
    uint32_t bytes_per_frame;      // RF_TRANSPORT_BYTES_PER_FRAME
    uint32_t ring_capacity_frames; // rf_frames_for_duration(sample_rate,
                                   // ring_duration_ms)
    uint32_t ring_duration_ms;     // [RF_RING_DURATION_MS_MIN, RF_RING_DURATION_MS_MAX]
    uint64_t creation_timestamp;   // Unix seconds, informational only
    uint8_t device_uid_hash[32];   // SHA-256 of the physical device UID

    // ===== RING INDICES (single writer each) =====
    _Atomic uint64_t write_index; // written only by the producer (driver)
    _Atomic uint64_t read_index;  // written only by the consumer (host)

    // ===== STATISTICS =====
    _Atomic uint64_t total_frames_written;
    _Atomic uint64_t total_frames_read;
    _Atomic uint64_t overrun_count;
    _Atomic uint64_t underrun_count;

    // ===== STATUS =====
    _Atomic uint32_t driver_connected;
    _Atomic uint32_t host_connected;
    _Atomic uint64_t driver_heartbeat;
    _Atomic uint64_t host_heartbeat;

    // ===== VOLUME CONTROL (driver writes, host validates) =====
    _Atomic float volume_scalar;
    _Atomic int32_t mute_state;

    uint8_t _reserved[96];

    // Interleaved float32 stereo, ring_capacity_frames frames.
    uint8_t audio_data[];
} RFSharedAudio;

RF_STATIC_ASSERT(sizeof(RFSharedAudio) == RF_AUDIO_HEADER_SIZE, "RFSharedAudio header must be 256 bytes");
RF_STATIC_ASSERT(offsetof(RFSharedAudio, write_index) == 80, "RFSharedAudio layout drift");
RF_STATIC_ASSERT(offsetof(RFSharedAudio, volume_scalar) == 152, "RFSharedAudio layout drift");
RF_STATIC_ASSERT(offsetof(RFSharedAudio, audio_data) == RF_AUDIO_HEADER_SIZE, "RFSharedAudio layout drift");

/** Locally owned copy of validated geometry. Never read geometry from shared
 * memory again. */
typedef struct {
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t capacity_frames;
    uint32_t bytes_per_frame;
    size_t mapping_length;
} RFAudioLayout;

typedef enum {
    RF_LAYOUT_OK = 0,
    RF_LAYOUT_ERR_NULL,
    RF_LAYOUT_ERR_TOO_SMALL,
    RF_LAYOUT_ERR_MAGIC,
    RF_LAYOUT_ERR_VERSION,
    RF_LAYOUT_ERR_HEADER_SIZE,
    RF_LAYOUT_ERR_SAMPLE_RATE,
    RF_LAYOUT_ERR_FORMAT,
    RF_LAYOUT_ERR_DURATION,
    RF_LAYOUT_ERR_CAPACITY,
    RF_LAYOUT_ERR_SIZE_MISMATCH,
    RF_LAYOUT_ERR_DEVICE
} RFLayoutStatus;

static inline bool rf_is_sample_rate_supported(uint32_t sample_rate) {
    for (int i = 0; i < RF_NUM_SAMPLE_RATES; i++) {
        if (RF_SUPPORTED_SAMPLE_RATES[i] == sample_rate) {
            return true;
        }
    }
    return false;
}

static inline uint32_t rf_frames_for_duration(uint32_t sample_rate, uint32_t duration_ms) {
    return (uint32_t)(((uint64_t)sample_rate * (uint64_t)duration_ms) / 1000u);
}

static inline uint32_t rf_bytes_per_sample(RFAudioFormat format) {
    return format == RF_FORMAT_FLOAT32 ? RF_TRANSPORT_BYTES_PER_SAMPLE : 0u;
}

/** Total mapping size for a ring, or 0 when capacity is out of range. */
static inline size_t rf_shared_audio_size(uint32_t capacity_frames) {
    if (capacity_frames == 0 || capacity_frames > RF_RING_CAPACITY_MAX_FRAMES) {
        return 0;
    }
    return (size_t)RF_AUDIO_HEADER_SIZE + (size_t)capacity_frames * (size_t)RF_TRANSPORT_BYTES_PER_FRAME;
}

static inline size_t rf_shared_audio_max_size(void) {
    return rf_shared_audio_size(RF_RING_CAPACITY_MAX_FRAMES);
}

/**
 * Initialize a freshly created mapping. Returns false (and writes nothing)
 * if parameters are invalid or mapped_length does not match exactly.
 */
static inline bool rf_shared_audio_init(RFSharedAudio* mem, size_t mapped_length, uint32_t sample_rate,
                                        uint32_t duration_ms, const uint8_t* device_uid_hash) {
    if (!mem || !device_uid_hash) return false;
    if (!rf_is_sample_rate_supported(sample_rate)) return false;
    if (duration_ms < RF_RING_DURATION_MS_MIN || duration_ms > RF_RING_DURATION_MS_MAX) return false;
    uint32_t capacity = rf_frames_for_duration(sample_rate, duration_ms);
    size_t expected = rf_shared_audio_size(capacity);
    if (expected == 0 || expected != mapped_length) return false;

    memset(mem, 0, mapped_length);
    mem->magic = RF_AUDIO_MAGIC;
    mem->protocol_version = RF_AUDIO_PROTOCOL_VERSION;
    mem->header_size = RF_AUDIO_HEADER_SIZE;
    mem->sample_rate = sample_rate;
    mem->channels = RF_TRANSPORT_CHANNELS;
    mem->format = RF_FORMAT_FLOAT32;
    mem->bytes_per_sample = RF_TRANSPORT_BYTES_PER_SAMPLE;
    mem->bytes_per_frame = RF_TRANSPORT_BYTES_PER_FRAME;
    mem->ring_capacity_frames = capacity;
    mem->ring_duration_ms = duration_ms;
    mem->creation_timestamp = (uint64_t)time(NULL);
    memcpy(mem->device_uid_hash, device_uid_hash, RF_UID_HASH_SIZE);

    RF_ATOMIC_STORE(&mem->write_index, 0);
    RF_ATOMIC_STORE(&mem->read_index, 0);
    RF_ATOMIC_STORE(&mem->host_connected, 1);
    RF_ATOMIC_STORE(&mem->volume_scalar,
                    0.0f); // silent until the driver publishes real volume
    RF_ATOMIC_STORE(&mem->mute_state, 0);
    return true;
}

/**
 * Validate a mapping and capture its geometry locally.
 * Every header field is read exactly once so concurrent peer writes cannot
 * make the checked value differ from the used value.
 * expected_uid_hash may be NULL to skip the device binding check.
 */
static inline RFLayoutStatus rf_validate_layout(const RFSharedAudio* mem, size_t mapped_length,
                                                const uint8_t* expected_uid_hash, RFAudioLayout* out) {
    if (!mem || !out) return RF_LAYOUT_ERR_NULL;
    if (mapped_length < RF_AUDIO_HEADER_SIZE) return RF_LAYOUT_ERR_TOO_SMALL;

    const uint32_t magic = mem->magic;
    const uint32_t version = mem->protocol_version;
    const uint32_t header_size = mem->header_size;
    const uint32_t sample_rate = mem->sample_rate;
    const uint32_t channels = mem->channels;
    const uint32_t format = mem->format;
    const uint32_t bytes_per_sample = mem->bytes_per_sample;
    const uint32_t bytes_per_frame = mem->bytes_per_frame;
    const uint32_t capacity = mem->ring_capacity_frames;
    const uint32_t duration_ms = mem->ring_duration_ms;
    uint8_t uid_hash[RF_UID_HASH_SIZE];
    memcpy(uid_hash, mem->device_uid_hash, RF_UID_HASH_SIZE);

    if (magic != RF_AUDIO_MAGIC) return RF_LAYOUT_ERR_MAGIC;
    if (version != RF_AUDIO_PROTOCOL_VERSION) return RF_LAYOUT_ERR_VERSION;
    if (header_size != RF_AUDIO_HEADER_SIZE) return RF_LAYOUT_ERR_HEADER_SIZE;
    if (!rf_is_sample_rate_supported(sample_rate)) return RF_LAYOUT_ERR_SAMPLE_RATE;
    if (channels != RF_TRANSPORT_CHANNELS || format != RF_FORMAT_FLOAT32 ||
        bytes_per_sample != RF_TRANSPORT_BYTES_PER_SAMPLE || bytes_per_frame != RF_TRANSPORT_BYTES_PER_FRAME) {
        return RF_LAYOUT_ERR_FORMAT;
    }
    if (duration_ms < RF_RING_DURATION_MS_MIN || duration_ms > RF_RING_DURATION_MS_MAX) {
        return RF_LAYOUT_ERR_DURATION;
    }
    if (capacity != rf_frames_for_duration(sample_rate, duration_ms)) return RF_LAYOUT_ERR_CAPACITY;
    const size_t expected = rf_shared_audio_size(capacity);
    if (expected == 0) return RF_LAYOUT_ERR_CAPACITY;
    if (expected != mapped_length) return RF_LAYOUT_ERR_SIZE_MISMATCH;
    if (expected_uid_hash && memcmp(uid_hash, expected_uid_hash, RF_UID_HASH_SIZE) != 0) {
        return RF_LAYOUT_ERR_DEVICE;
    }

    out->sample_rate = sample_rate;
    out->channels = channels;
    out->capacity_frames = capacity;
    out->bytes_per_frame = bytes_per_frame;
    out->mapping_length = mapped_length;
    return RF_LAYOUT_OK;
}

static inline const char* rf_layout_status_string(RFLayoutStatus status) {
    switch (status) {
        case RF_LAYOUT_OK: return "ok";
        case RF_LAYOUT_ERR_NULL: return "null";
        case RF_LAYOUT_ERR_TOO_SMALL: return "mapping too small";
        case RF_LAYOUT_ERR_MAGIC: return "bad magic";
        case RF_LAYOUT_ERR_VERSION: return "protocol version mismatch";
        case RF_LAYOUT_ERR_HEADER_SIZE: return "bad header size";
        case RF_LAYOUT_ERR_SAMPLE_RATE: return "unsupported sample rate";
        case RF_LAYOUT_ERR_FORMAT: return "unsupported format";
        case RF_LAYOUT_ERR_DURATION: return "bad ring duration";
        case RF_LAYOUT_ERR_CAPACITY: return "bad ring capacity";
        case RF_LAYOUT_ERR_SIZE_MISMATCH: return "mapping size mismatch";
        case RF_LAYOUT_ERR_DEVICE: return "device mismatch";
    }
    return "unknown";
}

static inline float* rf_audio_frames(RFSharedAudio* mem) {
    return (float*)(void*)mem->audio_data;
}

/**
 * Producer: append interleaved stereo samples. input_samples must be even.
 * Frames that do not fit are dropped (the producer never moves read_index).
 * Returns frames written.
 */
static inline uint32_t rf_ring_write(RFSharedAudio* mem, const RFAudioLayout* layout, const float* input,
                                     size_t input_samples) {
    if (!mem || !layout || !input || layout->capacity_frames == 0) return 0;
    const uint64_t capacity = layout->capacity_frames;
    const size_t channels = RF_TRANSPORT_CHANNELS;
    uint64_t frames = (uint64_t)(input_samples / channels);
    if (frames == 0) return 0;

    uint64_t w = RF_ATOMIC_LOAD(&mem->write_index);
    const uint64_t r = RF_ATOMIC_LOAD(&mem->read_index);
    uint64_t used = w - r;
    if (used > capacity) {
        // Consumer ahead of producer or corrupted indices: resync our own index
        // only.
        w = r;
        used = 0;
        RF_ATOMIC_ADD(&mem->overrun_count, 1);
    }

    const uint64_t free_frames = capacity - used;
    if (frames > free_frames) {
        frames = free_frames;
        RF_ATOMIC_ADD(&mem->overrun_count, 1);
    }
    if (frames > 0) {
        float* data = rf_audio_frames(mem);
        const uint64_t pos = w % capacity;
        const uint64_t first = (frames < capacity - pos) ? frames : capacity - pos;
        memcpy(data + pos * channels, input, (size_t)(first * channels) * sizeof(float));
        if (frames > first) {
            memcpy(data, input + first * channels, (size_t)((frames - first) * channels) * sizeof(float));
        }
    }

    RF_ATOMIC_STORE(&mem->write_index, w + frames);
    RF_ATOMIC_ADD(&mem->total_frames_written, frames);
    return (uint32_t)frames;
}

/**
 * Consumer: fill output (interleaved stereo, output_samples samples).
 * Missing frames are zero-filled. Returns frames read from the ring.
 */
static inline uint32_t rf_ring_read(RFSharedAudio* mem, const RFAudioLayout* layout, float* output,
                                    size_t output_samples) {
    if (!output) return 0;
    const size_t channels = RF_TRANSPORT_CHANNELS;
    const uint64_t wanted = (uint64_t)(output_samples / channels);
    if (!mem || !layout || layout->capacity_frames == 0) {
        memset(output, 0, output_samples * sizeof(float));
        return 0;
    }
    const uint64_t capacity = layout->capacity_frames;

    const uint64_t r = RF_ATOMIC_LOAD(&mem->read_index);
    const uint64_t w = RF_ATOMIC_LOAD(&mem->write_index);
    const uint64_t available = w - r;
    if (available > capacity) {
        // Impossible distance: drop everything and resync our own index.
        RF_ATOMIC_STORE(&mem->read_index, w);
        RF_ATOMIC_ADD(&mem->underrun_count, 1);
        memset(output, 0, output_samples * sizeof(float));
        return 0;
    }

    const uint64_t frames = (available < wanted) ? available : wanted;
    if (frames > 0) {
        const float* data = rf_audio_frames(mem);
        const uint64_t pos = r % capacity;
        const uint64_t first = (frames < capacity - pos) ? frames : capacity - pos;
        memcpy(output, data + pos * channels, (size_t)(first * channels) * sizeof(float));
        if (frames > first) {
            memcpy(output + first * channels, data, (size_t)((frames - first) * channels) * sizeof(float));
        }
    }
    const size_t copied_samples = (size_t)(frames * channels);
    if (copied_samples < output_samples) {
        memset(output + copied_samples, 0, (output_samples - copied_samples) * sizeof(float));
    }
    if (frames < wanted) {
        RF_ATOMIC_ADD(&mem->underrun_count, 1);
    }

    RF_ATOMIC_STORE(&mem->read_index, r + frames);
    RF_ATOMIC_ADD(&mem->total_frames_read, frames);
    return (uint32_t)frames;
}

/**
 * Consumer: drop everything currently queued.
 * Used when a ring becomes the active one again: whatever a producer wrote
 * while nobody consumed it is stale and must not be played.
 */
static inline void rf_ring_consumer_drain(RFSharedAudio* mem) {
    if (!mem) return;
    RF_ATOMIC_STORE(&mem->read_index, RF_ATOMIC_LOAD(&mem->write_index));
}

/** Frames currently queued, clamped to capacity (corrupt distances report 0).
 */
static inline uint32_t rf_ring_fill(const RFSharedAudio* mem, const RFAudioLayout* layout) {
    if (!mem || !layout) return 0;
    const uint64_t w = RF_ATOMIC_LOAD((_Atomic uint64_t*)&mem->write_index);
    const uint64_t r = RF_ATOMIC_LOAD((_Atomic uint64_t*)&mem->read_index);
    const uint64_t used = w - r;
    return used > layout->capacity_frames ? 0u : (uint32_t)used;
}

/**
 * Replace non-finite samples with silence and clamp to [-limit, limit].
 * Returns the number of non-finite samples found.
 */
static inline uint32_t rf_sanitize_samples(float* samples, size_t count, float limit) {
    uint32_t invalid = 0;
    if (!samples) return 0;
    for (size_t i = 0; i < count; i++) {
        float s = samples[i];
        if (!isfinite(s)) {
            samples[i] = 0.0f;
            invalid++;
        } else if (s > limit) {
            samples[i] = limit;
        } else if (s < -limit) {
            samples[i] = -limit;
        }
    }
    return invalid;
}

// ===== HEARTBEAT / STATUS =====

static inline void rf_update_driver_heartbeat(RFSharedAudio* mem) {
    RF_ATOMIC_ADD(&mem->driver_heartbeat, 1);
    RF_ATOMIC_STORE(&mem->driver_connected, 1);
}

static inline void rf_update_host_heartbeat(RFSharedAudio* mem) {
    RF_ATOMIC_ADD(&mem->host_heartbeat, 1);
    RF_ATOMIC_STORE(&mem->host_connected, 1);
}

static inline uint64_t rf_get_host_heartbeat(const RFSharedAudio* mem) {
    return RF_ATOMIC_LOAD((_Atomic uint64_t*)&mem->host_heartbeat);
}

static inline uint32_t rf_get_host_connected(const RFSharedAudio* mem) {
    return RF_ATOMIC_LOAD((_Atomic uint32_t*)&mem->host_connected);
}

static inline void rf_set_driver_connected(RFSharedAudio* mem, bool connected) {
    RF_ATOMIC_STORE(&mem->driver_connected, connected ? 1u : 0u);
}

// ===== VOLUME CONTROL =====

/** Clamp to [0, RF_VOLUME_MAX]; non-finite values become 0 (silence). */
static inline float rf_sanitize_volume(float value) {
    if (!isfinite(value) || value <= 0.0f) return 0.0f;
    return value > RF_VOLUME_MAX ? RF_VOLUME_MAX : value;
}

static inline void rf_store_volume_scalar(RFSharedAudio* mem, float value) {
    RF_ATOMIC_STORE(&mem->volume_scalar, rf_sanitize_volume(value));
}

static inline void rf_store_mute_state(RFSharedAudio* mem, bool muted) {
    RF_ATOMIC_STORE(&mem->mute_state, muted ? 1 : 0);
}

/** Host side: always returns a value in [0, RF_VOLUME_MAX]. */
static inline float rf_load_volume_scalar(const RFSharedAudio* mem) {
    return rf_sanitize_volume(RF_ATOMIC_LOAD((_Atomic float*)&mem->volume_scalar));
}

static inline bool rf_load_mute_state(const RFSharedAudio* mem) {
    return RF_ATOMIC_LOAD((_Atomic int32_t*)&mem->mute_state) != 0;
}

// ===== TELEMETRY =====

static inline uint64_t rf_get_underrun_count(const RFSharedAudio* mem) {
    return RF_ATOMIC_LOAD((_Atomic uint64_t*)&mem->underrun_count);
}

static inline uint64_t rf_get_overrun_count(const RFSharedAudio* mem) {
    return RF_ATOMIC_LOAD((_Atomic uint64_t*)&mem->overrun_count);
}

// ===== EQ CONTROL (app writes, host reads; separate mapping without audio)
// =====

#define RF_EQ_MAGIC 0x51454253u /* "SBEQ" */
#define RF_EQ_PROTOCOL_VERSION 0x00010000u
#define RF_EQ_CONTROL_SIZE 128u
#define RF_EQ_BAND_COUNT 10
#define RF_EQ_GAIN_LIMIT_DB 24.0f

typedef struct {
    float bands[10]; // dB
    float preamp;    // dB
    uint8_t bypass;  // 0 = active, non-zero = bypassed (normalized to 1 on load)
    uint8_t _pad[3];
} RFEQSnapshot;

typedef struct {
    uint32_t magic;
    uint32_t protocol_version;
    uint32_t header_size;
    uint32_t _pad0;
    uint8_t device_uid_hash[32];
    _Atomic uint32_t sequence; // SeqLock: odd while the writer is active
    uint32_t _pad1;
    RFEQSnapshot snapshot;
    uint8_t _reserved[24];
} RFEQControl;

RF_STATIC_ASSERT(sizeof(RFEQSnapshot) == 48, "RFEQSnapshot must be 48 bytes");
RF_STATIC_ASSERT(sizeof(RFEQControl) == RF_EQ_CONTROL_SIZE, "RFEQControl must be 128 bytes");
RF_STATIC_ASSERT(offsetof(RFEQControl, snapshot) == 56, "RFEQControl layout drift");

static inline void rf_eq_control_init(RFEQControl* ctl, const uint8_t* device_uid_hash) {
    memset(ctl, 0, sizeof(RFEQControl));
    ctl->magic = RF_EQ_MAGIC;
    ctl->protocol_version = RF_EQ_PROTOCOL_VERSION;
    ctl->header_size = RF_EQ_CONTROL_SIZE;
    memcpy(ctl->device_uid_hash, device_uid_hash, RF_UID_HASH_SIZE);
    RF_ATOMIC_STORE(&ctl->sequence, 0);
}

static inline bool rf_eq_control_validate(const RFEQControl* ctl, size_t mapped_length,
                                          const uint8_t* expected_uid_hash) {
    if (!ctl || mapped_length != RF_EQ_CONTROL_SIZE) return false;
    if (ctl->magic != RF_EQ_MAGIC || ctl->protocol_version != RF_EQ_PROTOCOL_VERSION ||
        ctl->header_size != RF_EQ_CONTROL_SIZE) {
        return false;
    }
    if (expected_uid_hash && memcmp(ctl->device_uid_hash, expected_uid_hash, RF_UID_HASH_SIZE) != 0) {
        return false;
    }
    return true;
}

static inline float rf_eq_clamp_db(float value) {
    if (value > RF_EQ_GAIN_LIMIT_DB) return RF_EQ_GAIN_LIMIT_DB;
    if (value < -RF_EQ_GAIN_LIMIT_DB) return -RF_EQ_GAIN_LIMIT_DB;
    return value;
}

/** Returns false if any value is non-finite; otherwise clamps and normalizes in
 * place. */
static inline bool rf_eq_snapshot_sanitize(RFEQSnapshot* s) {
    for (int i = 0; i < RF_EQ_BAND_COUNT; i++) {
        if (!isfinite(s->bands[i])) return false;
        s->bands[i] = rf_eq_clamp_db(s->bands[i]);
    }
    if (!isfinite(s->preamp)) return false;
    s->preamp = rf_eq_clamp_db(s->preamp);
    s->bypass = s->bypass != 0 ? 1 : 0;
    memset(s->_pad, 0, sizeof(s->_pad));
    return true;
}

/** Single writer (app). Invalid snapshots are not published. */
static inline bool rf_eq_store(RFEQControl* ctl, const RFEQSnapshot* snapshot) {
    RFEQSnapshot copy = *snapshot;
    if (!rf_eq_snapshot_sanitize(&copy)) return false;
    uint32_t seq = RF_ATOMIC_LOAD(&ctl->sequence);
    if (seq & 1u) seq++; // recover from a writer that died mid-update
    RF_ATOMIC_STORE(&ctl->sequence, seq + 1u);
    memcpy((void*)&ctl->snapshot, &copy, sizeof(RFEQSnapshot));
    RF_ATOMIC_STORE(&ctl->sequence, seq + 2u);
    return true;
}

/**
 * Reader (host render thread). Returns true only for a consistent, valid
 * snapshot; on false the caller must keep its previous snapshot.
 */
static inline bool rf_eq_load(const RFEQControl* ctl, RFEQSnapshot* out) {
    if (!ctl || !out) return false;
    for (int attempt = 0; attempt < 4; attempt++) {
        const uint32_t seq1 = RF_ATOMIC_LOAD((_Atomic uint32_t*)&ctl->sequence);
        if (seq1 & 1u) continue;
        RFEQSnapshot copy;
        memcpy(&copy, (const void*)&ctl->snapshot, sizeof(RFEQSnapshot));
        const uint32_t seq2 = RF_ATOMIC_LOAD((_Atomic uint32_t*)&ctl->sequence);
        if (seq1 != seq2) continue;
        if (!rf_eq_snapshot_sanitize(&copy)) return false;
        *out = copy;
        return true;
    }
    return false;
}

#ifdef __cplusplus
}
#endif

#endif // RF_SHARED_AUDIO_H
