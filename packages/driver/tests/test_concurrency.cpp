// Producer/consumer model of the driver and host. Build with
// -DSB_SANITIZE=thread to check the lock-free protocol with ThreadSanitizer.
#include "test_harness.h"
#include "test_support.h"

#include <atomic>
#include <chrono>
#include <thread>
#include <vector>

// Sequence numbers stay exactly representable as float.
constexpr uint32_t kSequenceModulo = 1u << 20;

SB_TEST(concurrency_spsc_ordering_with_hostile_geometry_writes) {
    TestRing ring(48000, 20);
    const uint32_t geometryCapacity = ring.capacity;
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> produced{0};
    std::atomic<bool> orderingBroken{false};

    std::thread producer([&] {
        std::vector<float> chunk(512 * 2);
        uint32_t next = 1;
        std::mt19937 rng(1);
        while (!stop.load()) {
            const uint32_t frames = 1 + rng() % 512;
            for (uint32_t i = 0; i < frames; i++) {
                chunk[i * 2] = chunk[i * 2 + 1] = static_cast<float>((next + i) % kSequenceModulo);
            }
            const uint32_t written = rf_ring_write(ring.Mem(), &ring.layout, chunk.data(), frames * 2);
            next += written;
            produced += written;
        }
    });

    std::thread consumer([&] {
        std::vector<float> chunk(384 * 2);
        uint32_t last = 0;
        while (!stop.load()) {
            const uint32_t read = rf_ring_read(ring.Mem(), &ring.layout, chunk.data(), chunk.size());
            for (uint32_t i = 0; i < read; i++) {
                const uint32_t expected = (last + 1) % kSequenceModulo;
                if (chunk[i * 2] != static_cast<float>(expected) || chunk[i * 2 + 1] != chunk[i * 2]) {
                    orderingBroken = true;
                }
                last = expected;
            }
        }
    });

    // A hostile peer rewriting header geometry must not affect callers that use
    // their validated local layout.
    std::thread vandal([&] {
        std::mt19937 rng(2);
        while (!stop.load()) {
            ring.Mem()->ring_capacity_frames = rng();
            ring.Mem()->channels = rng();
        }
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(750));
    stop = true;
    producer.join();
    consumer.join();
    vandal.join();

    CHECK(!orderingBroken.load());
    CHECK(produced.load() > geometryCapacity);
}
