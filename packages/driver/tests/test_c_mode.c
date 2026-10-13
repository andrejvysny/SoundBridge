/* Compiles both protocol headers as C11, the way the Swift importer sees them. */
#include "RFSecureIPC.h"
#include "RFSharedAudio.h"

int sb_c_mode_check(void) {
    RFEQSnapshot snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
    snapshot.bypass = 3;
    if (!rf_eq_snapshot_sanitize(&snapshot) || snapshot.bypass != 1) return 1;
    return rf_shared_audio_size(0) == 0 ? 0 : 1;
}
