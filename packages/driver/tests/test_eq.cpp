#include "test_harness.h"
#include "test_support.h"

#include <cmath>

namespace {

struct TestEQ {
    TestEQ() : buffer(RF_EQ_CONTROL_SIZE) {
        HashOf("eq-device", hash);
        rf_eq_control_init(Ctl(), hash);
    }
    RFEQControl* Ctl() { return static_cast<RFEQControl*>(static_cast<void*>(buffer.data)); }
    ExactBuffer buffer;
    uint8_t hash[RF_UID_HASH_SIZE];
};

RFEQSnapshot MakeSnapshot(float gain) {
    RFEQSnapshot s{};
    for (int i = 0; i < RF_EQ_BAND_COUNT; i++) s.bands[i] = gain + static_cast<float>(i) * 0.1f;
    s.preamp = -1.5f;
    s.bypass = 0;
    return s;
}

} // namespace

SB_TEST(eq_validate) {
    TestEQ eq;
    CHECK(rf_eq_control_validate(eq.Ctl(), RF_EQ_CONTROL_SIZE, eq.hash));
    CHECK(rf_eq_control_validate(eq.Ctl(), RF_EQ_CONTROL_SIZE, nullptr));
    CHECK(!rf_eq_control_validate(eq.Ctl(), RF_EQ_CONTROL_SIZE - 1, eq.hash));
    CHECK(!rf_eq_control_validate(eq.Ctl(), 4096, eq.hash));
    uint8_t other[RF_UID_HASH_SIZE];
    HashOf("other-device", other);
    CHECK(!rf_eq_control_validate(eq.Ctl(), RF_EQ_CONTROL_SIZE, other));
    eq.Ctl()->protocol_version = 0;
    CHECK(!rf_eq_control_validate(eq.Ctl(), RF_EQ_CONTROL_SIZE, eq.hash));
}

SB_TEST(eq_store_load_roundtrip) {
    TestEQ eq;
    RFEQSnapshot in = MakeSnapshot(3.0f);
    CHECK(rf_eq_store(eq.Ctl(), &in));
    RFEQSnapshot out{};
    CHECK(rf_eq_load(eq.Ctl(), &out));
    CHECK(std::memcmp(&in, &out, sizeof(in)) == 0);
}

SB_TEST(eq_load_normalizes_bypass_and_clamps) {
    TestEQ eq;
    RFEQSnapshot raw = MakeSnapshot(100.0f);
    raw.bands[3] = -500.0f;
    raw.bypass = 0x7f; // would be an invalid Bool if read directly from Swift
    std::memcpy(static_cast<void*>(&eq.Ctl()->snapshot), &raw, sizeof(raw));
    RFEQSnapshot out{};
    CHECK(rf_eq_load(eq.Ctl(), &out));
    CHECK_EQ(out.bypass, 1);
    CHECK_EQ(out.bands[0], RF_EQ_GAIN_LIMIT_DB);
    CHECK_EQ(out.bands[3], -RF_EQ_GAIN_LIMIT_DB);
}

SB_TEST(eq_rejects_non_finite_values) {
    TestEQ eq;
    RFEQSnapshot bad = MakeSnapshot(0.0f);
    bad.bands[2] = std::nanf("");
    CHECK(!rf_eq_store(eq.Ctl(), &bad));

    std::memcpy(static_cast<void*>(&eq.Ctl()->snapshot), &bad, sizeof(bad));
    RFEQSnapshot previous = MakeSnapshot(1.0f);
    RFEQSnapshot out = previous;
    CHECK(!rf_eq_load(eq.Ctl(), &out));
    CHECK(std::memcmp(&out, &previous, sizeof(out)) == 0); // caller keeps last good snapshot

    RFEQSnapshot infPreamp = MakeSnapshot(0.0f);
    infPreamp.preamp = HUGE_VALF;
    CHECK(!rf_eq_store(eq.Ctl(), &infPreamp));
}

SB_TEST(eq_stuck_writer) {
    TestEQ eq;
    RF_ATOMIC_STORE(&eq.Ctl()->sequence, 7u); // writer died mid-update
    RFEQSnapshot out{};
    CHECK(!rf_eq_load(eq.Ctl(), &out));
    RFEQSnapshot in = MakeSnapshot(2.0f);
    CHECK(rf_eq_store(eq.Ctl(), &in)); // next writer recovers to an even sequence
    CHECK_EQ(RF_ATOMIC_LOAD(&eq.Ctl()->sequence) % 2, 0u);
    CHECK(rf_eq_load(eq.Ctl(), &out));
}
