// Model of host mapping retirement: the render thread must never observe a
// session after the control thread has retired and poisoned it.
#include "../../host/Sources/CSoundBridgeAudio/include/RFRenderSlot.h"
#include "test_harness.h"
#include "test_support.h"

#include <atomic>
#include <chrono>
#include <thread>

SB_TEST(render_slot_retire_waits_for_readers) {
    RFRenderSlot* slot = rf_render_slot_create();
    CHECK(slot != nullptr);
    std::atomic<bool> stop{false};
    std::atomic<bool> sawRetired{false};
    std::atomic<uint64_t> reads{0};

    auto makeSession = [](uint64_t generation) {
        auto* session = new RFRenderSession{};
        session->generation = generation;
        return session;
    };
    rf_render_slot_exchange(slot, makeSession(1));

    std::thread render([&] {
        while (!stop.load()) {
            const RFRenderSession* session = rf_render_slot_acquire(slot);
            if (session) {
                if (rf_render_session_generation(session) == UINT64_MAX) sawRetired = true;
                reads++;
            }
            rf_render_slot_release(slot);
        }
    });

    for (uint64_t generation = 2; generation < 3000; generation++) {
        RFRenderSession* old = rf_render_slot_exchange(slot, (generation % 7) ? makeSession(generation) : nullptr);
        while (rf_render_slot_readers(slot) != 0) std::this_thread::yield();
        if (old) {
            old->generation = UINT64_MAX; // poison, then free: ASan/TSan catch late readers
            delete old;
        }
    }
    stop = true;
    render.join();
    delete rf_render_slot_exchange(slot, nullptr);
    std::free(slot);

    CHECK(!sawRetired.load());
    CHECK(reads.load() > 0);
}
