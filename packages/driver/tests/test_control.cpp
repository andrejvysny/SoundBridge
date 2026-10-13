#include "test_harness.h"
#include "test_support.h"

#include <string>
#include <vector>

namespace {

int Parse(const std::string& data, std::vector<RFControlEntry>* entries = nullptr) {
    std::vector<RFControlEntry> local(RF_CONTROL_MAX_DEVICES);
    auto& target = entries ? *entries : local;
    target.resize(RF_CONTROL_MAX_DEVICES);
    return rf_control_parse(data.data(), data.size(), target.data(), RF_CONTROL_MAX_DEVICES);
}

const std::string kHeader = std::string(RF_CONTROL_HEADER) + "\n";

} // namespace

SB_TEST(control_parse_valid) {
    std::vector<RFControlEntry> entries;
    CHECK_EQ(Parse(kHeader), 0);
    CHECK_EQ(Parse(kHeader + "uid-1\tDELL U2720Q\nuid:2/x y\t\xC3\xA9" "cran HDMI\nuid-3\t\n", &entries), 3);
    CHECK_EQ(std::string(entries[0].uid), "uid-1");
    CHECK_EQ(std::string(entries[0].name), "DELL U2720Q");
    CHECK_EQ(std::string(entries[1].uid), "uid:2/x y");
    CHECK_EQ(std::string(entries[2].name), "");
}

SB_TEST(control_parse_rejects_malformed) {
    CHECK_EQ(Parse(""), -1);
    CHECK_EQ(Parse("SOUNDBRIDGE-DEVICES 2\n"), -1);
    CHECK_EQ(Parse(RF_CONTROL_HEADER), -1);                       // header without newline
    CHECK_EQ(Parse(kHeader + "uid\tname"), -1);                   // last line not terminated
    CHECK_EQ(Parse(kHeader + "uid name\n"), -1);                  // no tab
    CHECK_EQ(Parse(kHeader + "\tname\n"), -1);                    // empty uid
    CHECK_EQ(Parse(kHeader + "uid\tna\x01me\n"), -1);             // control char
    CHECK_EQ(Parse(kHeader + "uid\tname\r\n"), -1);               // CR
    CHECK_EQ(Parse(kHeader + std::string("u\0d\tname\n", 9)), -1); // NUL
    CHECK_EQ(Parse(kHeader + "uid\tname\tmore\n"), -1);           // tab in name
    CHECK_EQ(Parse(kHeader + "uid\tname\nuid\tother\n"), -1);     // duplicate uid
    CHECK_EQ(Parse(kHeader + std::string(RF_DEVICE_UID_MAX + 1, 'u') + "\tname\n"), -1);
    CHECK_EQ(Parse(kHeader + "uid\t" + std::string(RF_DEVICE_NAME_MAX + 1, 'n') + "\n"), -1);
    CHECK(Parse(kHeader + std::string(RF_DEVICE_UID_MAX, 'u') + "\t" + std::string(RF_DEVICE_NAME_MAX, 'n') + "\n") == 1);
}

SB_TEST(control_parse_bounds_device_count_and_size) {
    std::string data = kHeader;
    for (int i = 0; i < RF_CONTROL_MAX_DEVICES; i++) data += "uid-" + std::to_string(i) + "\tname\n";
    CHECK_EQ(Parse(data), RF_CONTROL_MAX_DEVICES);
    CHECK_EQ(Parse(data + "one-more\tname\n"), -1);

    std::string huge(RF_CONTROL_FILE_MAX_SIZE + 1, 'x');
    RFControlEntry entry;
    CHECK_EQ(rf_control_parse(huge.data(), huge.size(), &entry, 1), -1);
    CHECK_EQ(rf_control_parse((kHeader + "a\tb\nc\td\n").c_str(), kHeader.size() + 8, &entry, 1), -1);
}

SB_TEST(control_parse_fuzz) {
    auto& rng = Rng();
    std::vector<RFControlEntry> entries(4);
    for (int i = 0; i < 20000; i++) {
        std::string data = (rng() % 2) ? kHeader : std::string();
        const size_t length = rng() % 600;
        for (size_t j = 0; j < length; j++) {
            const uint64_t pick = rng() % 10;
            data.push_back(pick == 0 ? '\n' : pick == 1 ? '\t' : static_cast<char>(rng()));
        }
        const int count = rf_control_parse(data.data(), data.size(), entries.data(), 4);
        CHECK(count >= -1 && count <= 4);
        for (int e = 0; e < count; e++) {
            CHECK(strnlen(entries[e].uid, sizeof(entries[e].uid)) <= RF_DEVICE_UID_MAX);
            CHECK(strnlen(entries[e].name, sizeof(entries[e].name)) <= RF_DEVICE_NAME_MAX);
        }
    }
}

SB_TEST(ipc_file_names_are_collision_resistant) {
    char a[RF_IPC_NAME_MAX], b[RF_IPC_NAME_MAX], c[RF_IPC_NAME_MAX], again[RF_IPC_NAME_MAX];
    // These three collided under the old ':' '/' ' ' -> '_' substitution.
    CHECK_EQ(rf_ipc_file_name(RF_IPC_AUDIO_PREFIX, "a:b", 3, a, sizeof(a)), 0);
    CHECK_EQ(rf_ipc_file_name(RF_IPC_AUDIO_PREFIX, "a/b", 3, b, sizeof(b)), 0);
    CHECK_EQ(rf_ipc_file_name(RF_IPC_AUDIO_PREFIX, "a_b", 3, c, sizeof(c)), 0);
    CHECK_EQ(rf_ipc_file_name(RF_IPC_AUDIO_PREFIX, "a:b", 3, again, sizeof(again)), 0);
    CHECK(std::strcmp(a, b) != 0 && std::strcmp(a, c) != 0 && std::strcmp(b, c) != 0);
    CHECK_EQ(std::strcmp(a, again), 0);
    CHECK_EQ(std::strlen(a), std::strlen(RF_IPC_AUDIO_PREFIX) + 32);
    CHECK(rf_ipc_name_is_valid(a));

    char small[8];
    CHECK_EQ(rf_ipc_file_name(RF_IPC_AUDIO_PREFIX, "a", 1, small, sizeof(small)), -1);
    CHECK_EQ(rf_ipc_file_name(RF_IPC_AUDIO_PREFIX, "", 0, a, sizeof(a)), -1);
    std::string longUID(RF_DEVICE_UID_MAX + 1, 'x');
    CHECK_EQ(rf_ipc_file_name(RF_IPC_AUDIO_PREFIX, longUID.data(), longUID.size(), a, sizeof(a)), -1);
}

SB_TEST(ipc_name_validation) {
    CHECK(!rf_ipc_name_is_valid(nullptr));
    CHECK(!rf_ipc_name_is_valid(""));
    CHECK(!rf_ipc_name_is_valid("."));
    CHECK(!rf_ipc_name_is_valid(".."));
    CHECK(!rf_ipc_name_is_valid("../devices.txt"));
    CHECK(!rf_ipc_name_is_valid("a/b"));
    CHECK(!rf_ipc_name_is_valid(std::string(RF_IPC_NAME_MAX, 'a').c_str()));
    CHECK(rf_ipc_name_is_valid(RF_IPC_CONTROL_FILE));
}

SB_TEST(bounce_token_validation) {
    const uint64_t now = 1'700'000'000'000ULL;
    RFBounceToken token;
    rf_bounce_token_init(&token, now);
    CHECK(rf_bounce_token_is_valid(&token, now, nullptr));
    CHECK(rf_bounce_token_is_valid(&token, now + RF_BOUNCE_MAX_AGE_MS, nullptr));
    CHECK(!rf_bounce_token_is_valid(&token, now + RF_BOUNCE_MAX_AGE_MS + 1, nullptr));
    CHECK(!rf_bounce_token_is_valid(&token, now - 1500, nullptr)); // from the future
    CHECK(!rf_bounce_token_is_valid(&token, now, token.nonce));    // replay
    RFBounceToken other;
    rf_bounce_token_init(&other, now);
    CHECK(rf_bounce_token_is_valid(&token, now, other.nonce));
    token.magic = 0;
    CHECK(!rf_bounce_token_is_valid(&token, now, nullptr));
    CHECK(!rf_bounce_token_is_valid(nullptr, now, nullptr));
}
