#pragma once

// Validated access to host-created IPC files. Header-only so the native test
// harness can exercise the exact code the driver runs.

#include "../include/RFSecureIPC.h"
#include "../include/RFSharedAudio.h"

#include <sys/mman.h>

#include <cerrno>
#include <memory>
#include <string>
#include <vector>

namespace soundbridge {

class UniqueFd {
public:
    UniqueFd() = default;
    explicit UniqueFd(int fd) : fd_(fd) {}
    UniqueFd(const UniqueFd&) = delete;
    UniqueFd& operator=(const UniqueFd&) = delete;
    UniqueFd(UniqueFd&& other) noexcept : fd_(other.Release()) {}
    UniqueFd& operator=(UniqueFd&& other) noexcept {
        if (this != &other) {
            Reset(other.Release());
        }
        return *this;
    }
    ~UniqueFd() { Reset(); }

    int Get() const { return fd_; }
    explicit operator bool() const { return fd_ >= 0; }
    int Release() {
        int fd = fd_;
        fd_ = -1;
        return fd;
    }
    void Reset(int fd = -1) {
        if (fd_ >= 0) close(fd_);
        fd_ = fd;
    }

private:
    int fd_ = -1;
};

/// Filesystem identity of a mapping's backing file. The host replaces files by
/// atomic rename, so a changed inode means "this mapping is stale".
struct MappingIdentity {
    dev_t device = 0;
    ino_t inode = 0;

    bool operator==(const MappingIdentity& other) const { return device == other.device && inode == other.inode; }
    bool operator!=(const MappingIdentity& other) const { return !(*this == other); }
    explicit operator bool() const { return inode != 0; }
};

struct OpenResult {
    RFLayoutStatus layout = RF_LAYOUT_OK;
    int error = 0; // errno from the filesystem step, 0 if the failure was layout validation
};

// Owns one validated mapping. The unmap length is captured at map time and is
// never recomputed from (peer-writable) header fields.
class SharedAudioMapping {
public:
    SharedAudioMapping(const SharedAudioMapping&) = delete;
    SharedAudioMapping& operator=(const SharedAudioMapping&) = delete;
    ~SharedAudioMapping() { munmap(base_, layout_.mapping_length); }

    static std::unique_ptr<SharedAudioMapping> Open(int dirfd, uid_t owner, const std::string& deviceUID, bool writable,
                                                    OpenResult* result) {
        OpenResult local;
        OpenResult& out = result ? *result : local;
        out = OpenResult{};

        char name[RF_IPC_NAME_MAX];
        if (rf_ipc_file_name(RF_IPC_AUDIO_PREFIX, deviceUID.data(), deviceUID.size(), name, sizeof(name)) != 0) {
            out.error = errno;
            return nullptr;
        }
        off_t size = 0;
        UniqueFd fd(rf_ipc_open_file(dirfd, name, writable ? O_RDWR : O_RDONLY, owner, RF_AUDIO_HEADER_SIZE,
                                     static_cast<off_t>(rf_shared_audio_max_size()), &size));
        if (!fd) {
            out.error = errno;
            return nullptr;
        }
        struct stat st{};
        if (fstat(fd.Get(), &st) != 0) {
            out.error = errno;
            return nullptr;
        }
        const size_t length = static_cast<size_t>(size);
        const int protection = PROT_READ | (writable ? PROT_WRITE : 0);
        void* base = mmap(nullptr, length, protection, MAP_SHARED, fd.Get(), 0);
        if (base == MAP_FAILED) {
            out.error = errno;
            return nullptr;
        }

        uint8_t hash[RF_UID_HASH_SIZE];
        rf_uid_hash(deviceUID.data(), deviceUID.size(), hash);
        RFAudioLayout layout{};
        out.layout = rf_validate_layout(static_cast<const RFSharedAudio*>(base), length, hash, &layout);
        if (out.layout != RF_LAYOUT_OK) {
            munmap(base, length);
            return nullptr;
        }
        return std::unique_ptr<SharedAudioMapping>(
            new SharedAudioMapping(base, layout, MappingIdentity{st.st_dev, st.st_ino}));
    }

    RFSharedAudio* Memory() const { return static_cast<RFSharedAudio*>(base_); }
    const RFAudioLayout& Layout() const { return layout_; }
    const MappingIdentity& Identity() const { return identity_; }

private:
    SharedAudioMapping(void* base, const RFAudioLayout& layout, const MappingIdentity& identity)
        : base_(base), layout_(layout), identity_(identity) {}

    void* base_;
    RFAudioLayout layout_;
    MappingIdentity identity_;
};

/// Identity of the file a device's mapping would currently come from, without
/// mapping it. Returns a falsy identity when the file is missing or untrusted.
inline MappingIdentity CurrentMappingIdentity(int dirfd, uid_t owner, const std::string& deviceUID) {
    char name[RF_IPC_NAME_MAX];
    if (rf_ipc_file_name(RF_IPC_AUDIO_PREFIX, deviceUID.data(), deviceUID.size(), name, sizeof(name)) != 0) {
        return MappingIdentity{};
    }
    UniqueFd fd(rf_ipc_open_file(dirfd, name, O_RDONLY, owner, RF_AUDIO_HEADER_SIZE,
                                 static_cast<off_t>(rf_shared_audio_max_size()), nullptr));
    struct stat st{};
    if (!fd || fstat(fd.Get(), &st) != 0) return MappingIdentity{};
    return MappingIdentity{st.st_dev, st.st_ino};
}

enum class ControlFileStatus { Ok, Missing, Invalid };

struct ControlDevice {
    std::string uid;
    std::string name;
};

inline ControlFileStatus ReadControlFile(int dirfd, uid_t owner, std::vector<ControlDevice>* devices) {
    devices->clear();
    off_t size = 0;
    UniqueFd fd(rf_ipc_open_file(dirfd, RF_IPC_CONTROL_FILE, O_RDONLY, owner, 0, RF_CONTROL_FILE_MAX_SIZE, &size));
    if (!fd) {
        return errno == ENOENT ? ControlFileStatus::Missing : ControlFileStatus::Invalid;
    }
    std::vector<char> data(static_cast<size_t>(size));
    if (size > 0 && rf_ipc_read_exact(fd.Get(), data.data(), data.size()) != 0) {
        return ControlFileStatus::Invalid;
    }
    std::vector<RFControlEntry> entries(RF_CONTROL_MAX_DEVICES);
    const int count = rf_control_parse(data.data(), data.size(), entries.data(), RF_CONTROL_MAX_DEVICES);
    if (count < 0) return ControlFileStatus::Invalid;
    for (int i = 0; i < count; i++) {
        devices->push_back(ControlDevice{entries[i].uid, entries[i].name});
    }
    return ControlFileStatus::Ok;
}

} // namespace soundbridge
