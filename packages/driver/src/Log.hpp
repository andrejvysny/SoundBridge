#pragma once

#include <os/log.h>

namespace soundbridge {

inline os_log_t DriverLog() {
    static os_log_t log = os_log_create("com.soundbridge.driver", "default");
    return log;
}

} // namespace soundbridge

// Dynamic strings default to <private> in unified logging; keep it that way for
// device names and UIDs. Never log pointers or sample data.
#define RF_LOG_ERROR(fmt, ...) os_log_error(soundbridge::DriverLog(), "[SoundBridge] " fmt, ##__VA_ARGS__)
#define RF_LOG_INFO(fmt, ...) os_log_info(soundbridge::DriverLog(), "[SoundBridge] " fmt, ##__VA_ARGS__)
