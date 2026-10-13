// Control thread hands replacement mappings to the "IO thread"; only the
// control thread may allocate or free. Run under ASan and TSan.
#include "MappingHandoff.hpp"
#include "test_harness.h"
#include "test_support.h"

#include <atomic>
#include <chrono>
#include <thread>

namespace {

struct Tracked {
    explicit Tracked(uint64_t id) : id(id) { live.fetch_add(1); }
    ~Tracked() {
        id = UINT64_MAX; // poison: a late reader trips ASan or this check
        live.fetch_sub(1);
    }
    uint64_t id;
    static std::atomic<int> live;
};

std::atomic<int> Tracked::live{0};

} // namespace

SB_TEST(handoff_basic_ownership) {
    soundbridge::MappingHandoff<Tracked> handoff;
    CHECK(handoff.TakePending() == nullptr);
    CHECK(handoff.Offer(std::make_unique<Tracked>(1)));
    CHECK(handoff.HasPending());

    // A second offer is refused while one is outstanding; the caller keeps it.
    auto rejected = std::make_unique<Tracked>(2);
    CHECK(!handoff.Offer(std::move(rejected)));
    CHECK(rejected != nullptr);

    Tracked* taken = handoff.TakePending();
    CHECK(taken != nullptr && taken->id == 1);
    CHECK(handoff.TakePending() == nullptr);
    CHECK(handoff.Retire(taken));

    // While the retired slot is full the IO side must not take another object.
    CHECK(handoff.Offer(std::make_unique<Tracked>(3)));
    CHECK(handoff.TakePending() == nullptr);
    handoff.Reap();
    Tracked* third = handoff.TakePending();
    CHECK(third != nullptr && third->id == 3);
    CHECK(handoff.Retire(third));
    handoff.Reap();
    CHECK_EQ(Tracked::live.load(), 1); // only the caller-owned refused object remains
}

SB_TEST(handoff_concurrent_replacement_frees_everything) {
    const int before = Tracked::live.load();
    {
        soundbridge::MappingHandoff<Tracked> handoff;
        std::atomic<bool> stop{false};
        std::atomic<uint64_t> adopted{0};
        std::atomic<bool> sawPoison{false};
        Tracked* current = new Tracked(0);

        std::thread io([&] {
            while (!stop.load()) {
                if (Tracked* next = handoff.TakePending()) {
                    Tracked* previous = current;
                    current = next;
                    if (current->id == UINT64_MAX) sawPoison = true;
                    CHECK(handoff.Retire(previous));
                    adopted++;
                }
                if (current->id == UINT64_MAX) sawPoison = true;
            }
        });

        for (uint64_t id = 1; id <= 20000; id++) {
            handoff.Reap();
            if (!handoff.Offer(std::make_unique<Tracked>(id))) {
                std::this_thread::yield();
            }
        }
        stop = true;
        io.join();
        handoff.Clear();
        delete current;
        CHECK(!sawPoison.load());
        CHECK(adopted.load() > 0);
    }
    CHECK_EQ(Tracked::live.load(), before);
}
