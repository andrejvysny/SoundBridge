#ifndef RF_RENDER_SLOT_H
#define RF_RENDER_SLOT_H

// Host-only: hands the active mapping to the realtime render callback without
// locks, allocation, or Swift reference counting on the audio thread.

#include "RFSharedAudio.h"

#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Immutable once published. Owned by the Swift mapping object. */
typedef struct {
    RFSharedAudio* audio;
    RFAudioLayout layout;
    RFEQControl* eq;
    uint64_t generation;
} RFRenderSession;

/**
 * Single-slot read-copy-update.
 * Reader: increment `readers`, then load `session`; decrement when done.
 * Writer: exchange `session`, then wait until `readers` is 0. Any reader that
 * incremented after that observation loads the new pointer, so the old session
 * may be reclaimed. The writer must never run on the audio thread.
 */
typedef struct {
    _Atomic(RFRenderSession*) session;
    _Atomic(uint32_t) readers;
} RFRenderSlot;

static inline RFRenderSlot* rf_render_slot_create(void) {
    RFRenderSlot* slot = (RFRenderSlot*)calloc(1, sizeof(RFRenderSlot));
    if (slot) {
        RF_ATOMIC_STORE(&slot->session, (RFRenderSession*)0);
        RF_ATOMIC_STORE(&slot->readers, 0u);
    }
    return slot;
}

static inline const RFRenderSession* rf_render_slot_acquire(RFRenderSlot* slot) {
    RF_ATOMIC_ADD(&slot->readers, 1u);
    return RF_ATOMIC_LOAD(&slot->session);
}

static inline void rf_render_slot_release(RFRenderSlot* slot) {
    __c11_atomic_fetch_sub(&slot->readers, 1u, __ATOMIC_SEQ_CST);
}

static inline RFRenderSession* rf_render_slot_exchange(RFRenderSlot* slot, RFRenderSession* session) {
    return __c11_atomic_exchange(&slot->session, session, __ATOMIC_SEQ_CST);
}

static inline uint32_t rf_render_slot_readers(RFRenderSlot* slot) {
    return RF_ATOMIC_LOAD(&slot->readers);
}

// Thin accessors so Swift never copies layout structs on the render thread.

static inline uint32_t rf_render_session_read(const RFRenderSession* session, float* output, size_t samples) {
    return rf_ring_read(session->audio, &session->layout, output, samples);
}

static inline bool rf_render_session_load_eq(const RFRenderSession* session, RFEQSnapshot* out) {
    return session->eq != 0 && rf_eq_load(session->eq, out);
}

static inline float rf_render_session_volume(const RFRenderSession* session) {
    return rf_load_volume_scalar(session->audio);
}

static inline bool rf_render_session_muted(const RFRenderSession* session) {
    return rf_load_mute_state(session->audio);
}

static inline uint64_t rf_render_session_generation(const RFRenderSession* session) {
    return session->generation;
}

#ifdef __cplusplus
}
#endif

#endif // RF_RENDER_SLOT_H
