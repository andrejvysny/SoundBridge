#pragma once

#include <cstdio>
#include <vector>

namespace sbtest {

struct TestCase {
    const char* name;
    void (*fn)();
};

std::vector<TestCase>& Registry();
extern int failures;

struct Registrar {
    Registrar(const char* name, void (*fn)()) { Registry().push_back({name, fn}); }
};

} // namespace sbtest

#define SB_TEST(name)                                                                                                  \
    static void name();                                                                                                \
    static sbtest::Registrar name##_registrar(#name, name);                                                            \
    static void name()

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        if (!(cond)) {                                                                                                 \
            std::fprintf(stderr, "    FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                   \
            sbtest::failures++;                                                                                        \
        }                                                                                                              \
    } while (0)

#define CHECK_EQ(a, b) CHECK((a) == (b))
