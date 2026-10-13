#include "SharedMapping.hpp"
#include "test_harness.h"
#include "test_support.h"

#include <sys/mman.h>
#include <sys/stat.h>

#include <string>

using namespace soundbridge;

namespace {

// Private scratch directory standing in for the session directory.
struct ScratchDir {
    ScratchDir() {
        const char* tmp = std::getenv("TMPDIR");
        path = std::string(tmp ? tmp : "/tmp") + "/sb-ipc-test.XXXXXX";
        CHECK(mkdtemp(path.data()) != nullptr);
        fd = UniqueFd(open(path.c_str(), O_RDONLY | O_DIRECTORY));
    }
    ~ScratchDir() {
        std::string command = "rm -rf '" + path + "'";
        (void)std::system(command.c_str());
    }
    std::string File(const std::string& name) const { return path + "/" + name; }

    void Write(const std::string& name, const std::string& data, mode_t mode = 0600) const {
        int file = open(File(name).c_str(), O_WRONLY | O_CREAT | O_TRUNC, mode);
        CHECK(file >= 0);
        CHECK_EQ(write(file, data.data(), data.size()), static_cast<ssize_t>(data.size()));
        fchmod(file, mode);
        close(file);
    }

    std::string path;
    UniqueFd fd;
};

std::string AudioFileName(const std::string& uid) {
    char name[RF_IPC_NAME_MAX];
    CHECK_EQ(rf_ipc_file_name(RF_IPC_AUDIO_PREFIX, uid.data(), uid.size(), name, sizeof(name)), 0);
    return name;
}

void CreateAudioFile(const ScratchDir& dir, const std::string& uid, const std::string& contentUID, size_t trim = 0) {
    const uint32_t capacity = rf_frames_for_duration(48000, 20);
    const size_t length = rf_shared_audio_size(capacity);
    std::string data(length, '\0');
    uint8_t hash[RF_UID_HASH_SIZE];
    HashOf(contentUID, hash);
    CHECK(rf_shared_audio_init(static_cast<RFSharedAudio*>(static_cast<void*>(data.data())), length, 48000, 20, hash));
    dir.Write(AudioFileName(uid), data.substr(0, length - trim));
}

} // namespace

SB_TEST(ipc_open_file_accepts_private_regular_file) {
    ScratchDir dir;
    dir.Write("ok", "hello");
    off_t size = -1;
    UniqueFd fd(rf_ipc_open_file(dir.fd.Get(), "ok", O_RDONLY, getuid(), 0, 64, &size));
    CHECK(fd);
    CHECK_EQ(size, 5);
}

SB_TEST(ipc_open_file_rejects_untrusted_files) {
    ScratchDir dir;
    dir.Write("target", "secret");
    dir.Write("world", "data", 0666);
    dir.Write("group", "data", 0640);
    dir.Write("big", std::string(100, 'x'));
    CHECK_EQ(symlink(dir.File("target").c_str(), dir.File("link").c_str()), 0);
    CHECK_EQ(link(dir.File("target").c_str(), dir.File("hardlink").c_str()), 0);
    CHECK_EQ(mkfifo(dir.File("fifo").c_str(), 0600), 0);
    CHECK_EQ(mkdir(dir.File("subdir").c_str(), 0700), 0);

    auto rejected = [&](const char* name, uid_t owner, off_t maxSize) {
        int fd = rf_ipc_open_file(dir.fd.Get(), name, O_RDONLY, owner, 0, maxSize, nullptr);
        if (fd >= 0) close(fd);
        return fd < 0;
    };
    CHECK(rejected("link", getuid(), 64));      // symlink (O_NOFOLLOW)
    CHECK(rejected("target", getuid(), 64));    // now has two links
    CHECK(rejected("hardlink", getuid(), 64));
    CHECK(rejected("world", getuid(), 64));     // group/other bits
    CHECK(rejected("group", getuid(), 64));
    CHECK(rejected("fifo", getuid(), 64));      // must not block, must not accept
    CHECK(rejected("subdir", getuid(), 64));
    CHECK(rejected("big", getuid(), 64));       // over max size
    CHECK(rejected("missing", getuid(), 64));
    CHECK(rejected("../x", getuid(), 64));      // path traversal
    dir.Write("mine", "data");
    CHECK(rejected("mine", getuid() + 1, 64));  // wrong owner
    CHECK(!rejected("mine", getuid(), 64));

    int flagsFd = rf_ipc_open_file(dir.fd.Get(), "mine", O_RDONLY | O_CREAT, getuid(), 0, 64, nullptr);
    CHECK(flagsFd < 0);
}

SB_TEST(ipc_dir_trust_rules) {
    struct stat st{};
    st.st_mode = S_IFDIR | 0700;
    st.st_uid = getuid();
    CHECK(rf_ipc_dir_stat_is_trusted(&st, getuid()));
    st.st_mode = S_IFDIR | 0755;
    CHECK(!rf_ipc_dir_stat_is_trusted(&st, getuid()));
    st.st_mode = S_IFDIR | 0700;
    CHECK(!rf_ipc_dir_stat_is_trusted(&st, getuid() + 1));
    st.st_mode = S_IFLNK | 0700;
    CHECK(!rf_ipc_dir_stat_is_trusted(&st, getuid()));
    // A uid that cannot have a session directory.
    CHECK(rf_ipc_open_dir(static_cast<uid_t>(4242424242u)) < 0);
}

SB_TEST(ipc_create_temp_and_commit_replace_atomically) {
    ScratchDir dir;
    const mode_t previousMask = umask(0);
    char temp[RF_IPC_NAME_MAX];
    UniqueFd fd(rf_ipc_create_temp(dir.fd.Get(), temp, sizeof(temp)));
    umask(previousMask);
    CHECK(fd);
    struct stat st{};
    CHECK_EQ(fstat(fd.Get(), &st), 0);
    CHECK_EQ(st.st_mode & 07777, 0600u);
    CHECK_EQ(rf_ipc_write_all(fd.Get(), "new", 3), 0);

    dir.Write("final", "old");
    UniqueFd reader(open(dir.File("final").c_str(), O_RDONLY));
    CHECK_EQ(rf_ipc_commit(dir.fd.Get(), temp, "final"), 0);
    char buffer[3];
    CHECK_EQ(rf_ipc_read_exact(reader.Get(), buffer, 3), 0); // old inode stays intact for existing readers
    CHECK(std::memcmp(buffer, "old", 3) == 0);
    UniqueFd fresh(rf_ipc_open_file(dir.fd.Get(), "final", O_RDONLY, getuid(), 3, 3, nullptr));
    CHECK(fresh);
    CHECK_EQ(rf_ipc_read_exact(fresh.Get(), buffer, 3), 0);
    CHECK(std::memcmp(buffer, "new", 3) == 0);
    CHECK_EQ(rf_ipc_commit(dir.fd.Get(), "final", "../escape"), -1);
}

SB_TEST(ipc_service_acl_grant_and_clear) {
    ScratchDir dir;
    dir.Write("acl", "x");
    UniqueFd fd(open(dir.File("acl").c_str(), O_RDONLY));
    CHECK_EQ(rf_ipc_grant_service_access(fd.Get(), false, true), 0);
    acl_t acl = acl_get_fd_np(fd.Get(), ACL_TYPE_EXTENDED);
    CHECK(acl != nullptr);
    acl_entry_t entry;
    int entries = 0;
    for (int id = ACL_FIRST_ENTRY; acl && acl_get_entry(acl, id, &entry) == 0; id = ACL_NEXT_ENTRY) entries++;
    CHECK_EQ(entries, 1);
    if (acl) acl_free(acl);

    struct stat st{};
    CHECK_EQ(fstat(fd.Get(), &st), 0);
    CHECK_EQ(st.st_mode & 077, 0u); // ACL does not widen mode bits
    CHECK_EQ(rf_ipc_clear_acl(fd.Get()), 0);
    acl = acl_get_fd_np(fd.Get(), ACL_TYPE_EXTENDED);
    entries = 0;
    for (int id = ACL_FIRST_ENTRY; acl && acl_get_entry(acl, id, &entry) == 0; id = ACL_NEXT_ENTRY) entries++;
    CHECK_EQ(entries, 0);
    if (acl) acl_free(acl);
}

SB_TEST(ipc_mapping_open_validates_file_and_content) {
    ScratchDir dir;
    OpenResult result;

    CreateAudioFile(dir, "dev-ok", "dev-ok");
    auto mapping = SharedAudioMapping::Open(dir.fd.Get(), getuid(), "dev-ok", true, &result);
    CHECK(mapping != nullptr);
    if (mapping) CHECK_EQ(mapping->Layout().capacity_frames, rf_frames_for_duration(48000, 20));

    CreateAudioFile(dir, "dev-swapped", "some-other-device");
    CHECK(SharedAudioMapping::Open(dir.fd.Get(), getuid(), "dev-swapped", true, &result) == nullptr);
    CHECK_EQ(result.layout, RF_LAYOUT_ERR_DEVICE);

    CreateAudioFile(dir, "dev-truncated", "dev-truncated", 8);
    CHECK(SharedAudioMapping::Open(dir.fd.Get(), getuid(), "dev-truncated", true, &result) == nullptr);
    CHECK_EQ(result.layout, RF_LAYOUT_ERR_SIZE_MISMATCH);

    dir.Write(AudioFileName("dev-tiny"), std::string(16, '\0'));
    CHECK(SharedAudioMapping::Open(dir.fd.Get(), getuid(), "dev-tiny", true, &result) == nullptr);
    CHECK_EQ(result.error, EFBIG);

    CreateAudioFile(dir, "dev-world", "dev-world");
    chmod(dir.File(AudioFileName("dev-world")).c_str(), 0666);
    CHECK(SharedAudioMapping::Open(dir.fd.Get(), getuid(), "dev-world", true, &result) == nullptr);
    CHECK_EQ(result.error, EPERM);

    CHECK(SharedAudioMapping::Open(dir.fd.Get(), getuid(), "dev-missing", false, &result) == nullptr);
    CHECK_EQ(result.error, ENOENT);
}

// The driver service is granted search (+list) on the session directory, not
// full read: opening it must work with search-only permission.
SB_TEST(ipc_open_dir_needs_only_search_permission) {
    ScratchDir dir;
    dir.Write("file", "data");
    CHECK_EQ(chmod(dir.path.c_str(), 0100), 0); // execute/search only
    UniqueFd searchOnly(rf_ipc_open_dir_fd(dir.path.c_str()));
    CHECK(searchOnly);
    if (searchOnly) {
        struct stat st{};
        CHECK_EQ(fstat(searchOnly.Get(), &st), 0);
        UniqueFd file(rf_ipc_open_file(searchOnly.Get(), "file", O_RDONLY, getuid(), 0, 64, nullptr));
        CHECK(file);
    }
    CHECK_EQ(chmod(dir.path.c_str(), 0700), 0);
}

SB_TEST(ipc_remove_session_artifacts_keeps_only_the_lock) {
    ScratchDir dir;
    dir.Write(RF_IPC_HOST_LOCK_FILE, "");
    dir.Write(RF_IPC_CONTROL_FILE, "x");
    dir.Write(RF_IPC_BOUNCE_FILE, "x");
    dir.Write(AudioFileName("stale-device"), std::string(64, 'a'));
    dir.Write(std::string(RF_IPC_EQ_PREFIX) + "0123456789abcdef0123456789abcdef", "x");
    CHECK_EQ(rf_ipc_remove_session_artifacts(dir.fd.Get()), 4);

    std::vector<std::string> remaining;
    DIR* handle = opendir(dir.path.c_str());
    CHECK(handle != nullptr);
    while (struct dirent* entry = readdir(handle)) {
        const std::string name = entry->d_name;
        if (name != "." && name != "..") remaining.push_back(name);
    }
    if (handle) closedir(handle);
    CHECK_EQ(remaining.size(), 1u);
    if (!remaining.empty()) CHECK_EQ(remaining[0], std::string(RF_IPC_HOST_LOCK_FILE));
    CHECK_EQ(rf_ipc_remove_session_artifacts(dir.fd.Get()), 0);
}

SB_TEST(ipc_read_control_file) {
    ScratchDir dir;
    std::vector<ControlDevice> devices;
    CHECK(ReadControlFile(dir.fd.Get(), getuid(), &devices) == ControlFileStatus::Missing);

    dir.Write(RF_IPC_CONTROL_FILE, std::string(RF_CONTROL_HEADER) + "\nuid-1\tMonitor\n");
    CHECK(ReadControlFile(dir.fd.Get(), getuid(), &devices) == ControlFileStatus::Ok);
    CHECK_EQ(devices.size(), 1u);
    if (!devices.empty()) CHECK_EQ(devices[0].name, "Monitor");

    dir.Write(RF_IPC_CONTROL_FILE, "Monitor|uid-1\n"); // legacy format
    CHECK(ReadControlFile(dir.fd.Get(), getuid(), &devices) == ControlFileStatus::Invalid);
    CHECK(devices.empty());

    unlink(dir.File(RF_IPC_CONTROL_FILE).c_str());
    dir.Write("elsewhere", std::string(RF_CONTROL_HEADER) + "\n");
    CHECK_EQ(symlink(dir.File("elsewhere").c_str(), dir.File(RF_IPC_CONTROL_FILE).c_str()), 0);
    CHECK(ReadControlFile(dir.fd.Get(), getuid(), &devices) == ControlFileStatus::Invalid);
}
