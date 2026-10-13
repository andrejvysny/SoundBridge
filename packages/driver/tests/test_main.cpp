#include "test_harness.h"

#include <cstring>

extern "C" int sb_c_mode_check(void);

namespace sbtest {

std::vector<TestCase>& Registry() {
    static std::vector<TestCase> tests;
    return tests;
}

int failures = 0;

} // namespace sbtest

// Usage: soundbridge_protocol_tests [name-substring]
int main(int argc, char** argv) {
    const char* filter = argc > 1 ? argv[1] : nullptr;
    int run = 0;
    CHECK_EQ(sb_c_mode_check(), 0);
    for (const auto& test : sbtest::Registry()) {
        if (filter && !std::strstr(test.name, filter)) continue;
        const int before = sbtest::failures;
        test.fn();
        run++;
        std::printf("%s %s\n", sbtest::failures == before ? "PASS" : "FAIL", test.name);
    }
    std::printf("\n%d tests, %d failed checks\n", run, sbtest::failures);
    return sbtest::failures == 0 ? 0 : 1;
}
