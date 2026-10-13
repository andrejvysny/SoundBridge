#ifndef RF_SECURE_IPC_H
#define RF_SECURE_IPC_H

/*
 * Filesystem rendezvous for SoundBridge IPC.
 *
 * All IPC files live in a per-user session directory
 *   /private/tmp/com.soundbridge.<uid>/
 * owned by that user with mode 0700. The HAL driver service runs as
 * `_coreaudiod`, so it is granted access through explicit ACL entries
 * instead of world permission bits. Other local users cannot list, read,
 * create, or replace anything inside the directory.
 *
 * Residual risk (documented in SECURITY.md): processes running as the same
 * user can still reach these files. Excluding them needs an authenticated
 * Mach/XPC transport.
 *
 * Identical copies live next to RFSharedAudio.h in all three packages.
 */

#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <membership.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RF_IPC_DIR_PREFIX "/private/tmp/com.soundbridge."
#define RF_IPC_PATH_MAX 128
#define RF_IPC_NAME_MAX 64
#define RF_IPC_CONTROL_FILE "devices.txt"
#define RF_IPC_BOUNCE_FILE "bounce-request"
#define RF_IPC_HOST_LOCK_FILE "host.lock"
#define RF_IPC_AUDIO_PREFIX "audio-"
#define RF_IPC_EQ_PREFIX "eq-"
#define RF_IPC_SERVICE_USER "_coreaudiod"

#define RF_DEVICE_UID_MAX 256
#define RF_DEVICE_NAME_MAX 256
#define RF_CONTROL_FILE_MAX_SIZE 65536
#define RF_CONTROL_MAX_DEVICES 32
#define RF_CONTROL_HEADER "SOUNDBRIDGE-DEVICES 3"

// ===== NAMING =====

/** SHA-256 of a device UID. Collision resistant, unlike character substitution.
 */
static inline void rf_uid_hash(const char* uid, size_t uid_length, uint8_t out[32]) {
    CC_SHA256(uid, (CC_LONG)uid_length, out);
}

/** "<prefix><32 hex chars>" for a device UID. Returns 0 or -1. */
static inline int rf_ipc_file_name(const char* prefix, const char* uid, size_t uid_length, char* out,
                                   size_t out_capacity) {
    static const char hex[] = "0123456789abcdef";
    uint8_t hash[32];
    char digest[33];
    if (!prefix || !uid || !out || uid_length == 0 || uid_length > RF_DEVICE_UID_MAX) {
        errno = EINVAL;
        return -1;
    }
    rf_uid_hash(uid, uid_length, hash);
    for (int i = 0; i < 16; i++) {
        digest[i * 2] = hex[hash[i] >> 4];
        digest[i * 2 + 1] = hex[hash[i] & 0x0f];
    }
    digest[32] = '\0';
    int written = snprintf(out, out_capacity, "%s%s", prefix, digest);
    if (written < 0 || (size_t)written >= out_capacity) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}

static inline int rf_ipc_dir_path(uid_t owner, char* out, size_t out_capacity) {
    int written = snprintf(out, out_capacity, "%s%u", RF_IPC_DIR_PREFIX, (unsigned)owner);
    if (written < 0 || (size_t)written >= out_capacity) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}

/** Plain file name: non-empty, bounded, no path separators, no dot entries. */
static inline bool rf_ipc_name_is_valid(const char* name) {
    if (!name || name[0] == '\0') return false;
    size_t length = strnlen(name, RF_IPC_NAME_MAX);
    if (length >= RF_IPC_NAME_MAX) return false;
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) return false;
    return strchr(name, '/') == NULL;
}

// ===== VALIDATION =====

static inline bool rf_ipc_dir_stat_is_trusted(const struct stat* st, uid_t owner) {
    return S_ISDIR(st->st_mode) && st->st_uid == owner && (st->st_mode & 077) == 0;
}

static inline bool rf_ipc_file_stat_is_trusted(const struct stat* st, uid_t owner) {
    return S_ISREG(st->st_mode) && st->st_uid == owner && st->st_nlink == 1 && (st->st_mode & 077) == 0;
}

/**
 * Open a directory for use as an `openat` base.
 *
 * O_SEARCH needs only search permission, which is all the driver service is
 * granted on the session directory (O_RDONLY would require read/list access).
 * Older kernels that reject O_EXEC fall back to O_RDONLY, which works for the
 * owning user.
 */
static inline int rf_ipc_open_dir_fd(const char* path) {
    int fd = open(path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 && (errno == EINVAL || errno == ENOTSUP)) {
        fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }
    return fd;
}

/**
 * Open the session directory of `owner` without following a symlink at the
 * final component and verify ownership/mode on the opened descriptor.
 */
static inline int rf_ipc_open_dir(uid_t owner) {
    char path[RF_IPC_PATH_MAX];
    struct stat st;
    if (rf_ipc_dir_path(owner, path, sizeof(path)) != 0) return -1;
    int fd = rf_ipc_open_dir_fd(path);
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0 || !rf_ipc_dir_stat_is_trusted(&st, owner)) {
        close(fd);
        errno = EPERM;
        return -1;
    }
    return fd;
}

/**
 * Open an existing file inside a trusted directory. `flags` must not contain
 * O_CREAT. The descriptor is rejected unless it is a regular, singly linked
 * file owned by `owner`, without group/other bits, and its size is within
 * [min_size, max_size]. The observed size is returned through out_size.
 */
static inline int rf_ipc_open_file(int dirfd, const char* name, int flags, uid_t owner, off_t min_size, off_t max_size,
                                   off_t* out_size) {
    struct stat st;
    if (dirfd < 0 || !rf_ipc_name_is_valid(name) || (flags & O_CREAT)) {
        errno = EINVAL;
        return -1;
    }
    int fd = openat(dirfd, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0 || !rf_ipc_file_stat_is_trusted(&st, owner)) {
        close(fd);
        errno = EPERM;
        return -1;
    }
    if (st.st_size < min_size || st.st_size > max_size) {
        close(fd);
        errno = EFBIG;
        return -1;
    }
    if (out_size) *out_size = st.st_size;
    return fd;
}

// ===== CREATION (session owner only) =====

/** Grant the HAL driver service account access through an explicit ACL
 * (replaces existing ACL). */
static inline int rf_ipc_grant_service_access(int fd, bool is_directory, bool allow_write) {
    struct passwd pwd;
    struct passwd* result = NULL;
    char buffer[1024];
    uuid_t uuid;
    acl_t acl = NULL;
    acl_entry_t entry;
    acl_permset_t permset;
    int rc = -1;

    if (getpwnam_r(RF_IPC_SERVICE_USER, &pwd, buffer, sizeof(buffer), &result) != 0 || !result) {
        errno = ENOENT;
        return -1;
    }
    if (mbr_uid_to_uuid(pwd.pw_uid, uuid) != 0) {
        errno = ENOENT;
        return -1;
    }
    acl = acl_init(1);
    if (!acl) return -1;
    if (acl_create_entry(&acl, &entry) != 0) goto done;
    if (acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) != 0) goto done;
    if (acl_set_qualifier(entry, uuid) != 0) goto done;
    if (acl_get_permset(entry, &permset) != 0) goto done;
    acl_clear_perms(permset);
    if (is_directory) {
        // Search reaches known names; list is granted because a fallback
        // O_RDONLY open (pre-O_SEARCH kernels) needs read access. Names are
        // SHA-256 digests of device UIDs.
        acl_add_perm(permset, ACL_SEARCH);
        acl_add_perm(permset, ACL_LIST_DIRECTORY);
    } else {
        acl_add_perm(permset, ACL_READ_DATA);
        if (allow_write) acl_add_perm(permset, ACL_WRITE_DATA);
    }
    if (acl_set_permset(entry, permset) != 0) goto done;
    rc = acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED);
done:
    acl_free(acl);
    return rc;
}

/** Remove any extended ACL (used for files the driver must not read). */
static inline int rf_ipc_clear_acl(int fd) {
    acl_t acl = acl_init(0);
    if (!acl) return -1;
    int rc = acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED);
    acl_free(acl);
    return rc;
}

/**
 * Create (or adopt) the caller's own session directory and return a
 * descriptor for it. Fails closed if the path exists but belongs to another
 * user or is not a directory.
 */
static inline int rf_ipc_create_dir(bool grant_service) {
    char path[RF_IPC_PATH_MAX];
    struct stat st;
    uid_t owner = geteuid();
    if (rf_ipc_dir_path(owner, path, sizeof(path)) != 0) return -1;
    if (mkdir(path, 0700) != 0 && errno != EEXIST) return -1;

    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != owner) {
        close(fd);
        errno = EPERM;
        return -1;
    }
    if ((st.st_mode & 07777) != 0700 && fchmod(fd, 0700) != 0) {
        close(fd);
        return -1;
    }
    if (grant_service && rf_ipc_grant_service_access(fd, true, false) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/**
 * Exclusively create a uniquely named 0600 temp file inside dirfd.
 * The name is written to name_out. Commit with rf_ipc_commit().
 */
static inline int rf_ipc_create_temp(int dirfd, char* name_out, size_t name_capacity) {
    static const char hex[] = "0123456789abcdef";
    if (dirfd < 0 || !name_out || name_capacity < 22) {
        errno = EINVAL;
        return -1;
    }
    for (int attempt = 0; attempt < 8; attempt++) {
        uint8_t random_bytes[8];
        arc4random_buf(random_bytes, sizeof(random_bytes));
        memcpy(name_out, ".tmp-", 5);
        for (int i = 0; i < 8; i++) {
            name_out[5 + i * 2] = hex[random_bytes[i] >> 4];
            name_out[5 + i * 2 + 1] = hex[random_bytes[i] & 0x0f];
        }
        name_out[21] = '\0';
        int fd = openat(dirfd, name_out, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0) {
            if (fchmod(fd, 0600) != 0) {
                close(fd);
                unlinkat(dirfd, name_out, 0);
                return -1;
            }
            return fd;
        }
        if (errno != EEXIST) return -1;
    }
    errno = EEXIST;
    return -1;
}

/**
 * Open (creating if needed) the host single-instance lock file. The lock is
 * held with flock(); the file itself carries no data.
 */
static inline int rf_ipc_open_lock_file(int dirfd, bool create) {
    struct stat st;
    int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (create ? O_CREAT : 0);
    int fd = openat(dirfd, RF_IPC_HOST_LOCK_FILE, flags, 0600);
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0 || !rf_ipc_file_stat_is_trusted(&st, geteuid())) {
        close(fd);
        errno = EPERM;
        return -1;
    }
    return fd;
}

/** Atomically replace final_name with temp_name inside dirfd. */
static inline int rf_ipc_commit(int dirfd, const char* temp_name, const char* final_name) {
    if (!rf_ipc_name_is_valid(temp_name) || !rf_ipc_name_is_valid(final_name)) {
        errno = EINVAL;
        return -1;
    }
    return renameat(dirfd, temp_name, dirfd, final_name);
}

/**
 * Remove every session file except the lock, for use right after taking the
 * single-instance lock: a crashed host leaves audio and EQ mappings behind,
 * and nothing else owns them. Returns the number of files removed, or -1.
 */
static inline int rf_ipc_remove_session_artifacts(int dirfd) {
    int duplicate = dup(dirfd);
    if (duplicate < 0) return -1;
    DIR* dir = fdopendir(duplicate);
    if (!dir) {
        close(duplicate);
        return -1;
    }
    int removed = 0;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (strcmp(entry->d_name, RF_IPC_HOST_LOCK_FILE) == 0) continue;
        if (!rf_ipc_name_is_valid(entry->d_name)) continue;
        if (unlinkat(dirfd, entry->d_name, 0) == 0) removed++;
    }
    closedir(dir);
    return removed;
}

static inline int rf_ipc_unlink(int dirfd, const char* name) {
    if (!rf_ipc_name_is_valid(name)) {
        errno = EINVAL;
        return -1;
    }
    return unlinkat(dirfd, name, 0);
}

/** Write the whole buffer, retrying on partial writes and EINTR. */
static inline int rf_ipc_write_all(int fd, const void* data, size_t length) {
    const uint8_t* cursor = (const uint8_t*)data;
    while (length > 0) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        cursor += written;
        length -= (size_t)written;
    }
    return 0;
}

/** Read exactly `length` bytes. */
static inline int rf_ipc_read_exact(int fd, void* data, size_t length) {
    uint8_t* cursor = (uint8_t*)data;
    while (length > 0) {
        ssize_t got = read(fd, cursor, length);
        if (got < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (got == 0) {
            errno = EIO;
            return -1;
        }
        cursor += got;
        length -= (size_t)got;
    }
    return 0;
}

/** UID of the active console session, or -1 when nobody is logged in. */
static inline int rf_ipc_console_uid(uid_t* out) {
    struct stat st;
    if (!out || stat("/dev/console", &st) != 0) return -1;
    if (st.st_uid == 0) {
        errno = ESRCH;
        return -1;
    }
    *out = st.st_uid;
    return 0;
}

// ===== DEVICE CONTROL FILE =====
//
// Format:
//   SOUNDBRIDGE-DEVICES 3\n
//   <device uid>\t<device name>\n   (repeated, at most RF_CONTROL_MAX_DEVICES)
// Fields must be non-empty (name may be empty), bounded, and free of control
// characters. Any violation rejects the whole file.

typedef struct {
    char uid[RF_DEVICE_UID_MAX + 1];
    char name[RF_DEVICE_NAME_MAX + 1];
} RFControlEntry;

static inline bool rf_control_field_is_valid(const char* start, size_t length, size_t max_length, bool allow_empty) {
    if (length > max_length || (!allow_empty && length == 0)) return false;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)start[i];
        if (c < 0x20 || c == 0x7f) return false;
    }
    return true;
}

/** Returns the entry count, or -1 when the file is malformed. */
static inline int rf_control_parse(const char* data, size_t length, RFControlEntry* entries, int max_entries) {
    const size_t header_length = sizeof(RF_CONTROL_HEADER) - 1;
    int count = 0;
    if (!data || !entries || max_entries <= 0 || length > RF_CONTROL_FILE_MAX_SIZE) return -1;
    if (length < header_length + 1 || memcmp(data, RF_CONTROL_HEADER, header_length) != 0 ||
        data[header_length] != '\n') {
        return -1;
    }
    size_t pos = header_length + 1;
    while (pos < length) {
        const char* line = data + pos;
        const char* newline = (const char*)memchr(line, '\n', length - pos);
        if (!newline) return -1; // every line, including the last, is newline-terminated
        size_t line_length = (size_t)(newline - line);
        pos += line_length + 1;

        const char* tab = (const char*)memchr(line, '\t', line_length);
        if (!tab) return -1;
        size_t uid_length = (size_t)(tab - line);
        size_t name_length = line_length - uid_length - 1;
        const char* name = tab + 1;
        if (!rf_control_field_is_valid(line, uid_length, RF_DEVICE_UID_MAX, false) ||
            !rf_control_field_is_valid(name, name_length, RF_DEVICE_NAME_MAX, true)) {
            return -1;
        }
        if (count >= max_entries || count >= RF_CONTROL_MAX_DEVICES) return -1;
        for (int i = 0; i < count; i++) {
            if (strlen(entries[i].uid) == uid_length && memcmp(entries[i].uid, line, uid_length) == 0) {
                return -1;
            }
        }
        memcpy(entries[count].uid, line, uid_length);
        entries[count].uid[uid_length] = '\0';
        memcpy(entries[count].name, name, name_length);
        entries[count].name[name_length] = '\0';
        count++;
    }
    return count;
}

// ===== RECONNECT (BOUNCE) REQUEST TOKEN =====

#define RF_BOUNCE_MAGIC 0x52424253u /* "SBBR" */
#define RF_BOUNCE_VERSION 1u
#define RF_BOUNCE_TOKEN_SIZE 32u
#define RF_BOUNCE_MAX_AGE_MS 5000u

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t created_ms; // CLOCK_REALTIME milliseconds
    uint8_t nonce[16];
} RFBounceToken;

#ifdef __cplusplus
static_assert(sizeof(RFBounceToken) == RF_BOUNCE_TOKEN_SIZE, "RFBounceToken must be 32 bytes");
#else
_Static_assert(sizeof(RFBounceToken) == RF_BOUNCE_TOKEN_SIZE, "RFBounceToken must be 32 bytes");
#endif

static inline uint64_t rf_realtime_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static inline void rf_bounce_token_init(RFBounceToken* token, uint64_t now_ms) {
    memset(token, 0, sizeof(RFBounceToken));
    token->magic = RF_BOUNCE_MAGIC;
    token->version = RF_BOUNCE_VERSION;
    token->created_ms = now_ms;
    arc4random_buf(token->nonce, sizeof(token->nonce));
}

/** Fresh (small clock skew tolerated) and not a replay of last_nonce. */
static inline bool rf_bounce_token_is_valid(const RFBounceToken* token, uint64_t now_ms, const uint8_t* last_nonce) {
    if (!token || token->magic != RF_BOUNCE_MAGIC || token->version != RF_BOUNCE_VERSION) return false;
    if (token->created_ms > now_ms + 1000u) return false;
    if (now_ms > token->created_ms && now_ms - token->created_ms > RF_BOUNCE_MAX_AGE_MS) return false;
    if (last_nonce && memcmp(token->nonce, last_nonce, sizeof(token->nonce)) == 0) return false;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif // RF_SECURE_IPC_H
