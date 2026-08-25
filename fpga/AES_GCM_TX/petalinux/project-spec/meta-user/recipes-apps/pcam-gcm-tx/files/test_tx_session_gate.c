#define main pcam_gcm_udp_tx_program_main
#include "pcam-gcm-udp-tx.c"
#undef main

#include <assert.h>

int main(void)
{
    struct session_hw_state state = {0};
    const uint32_t session = 0x11223344U;

    stop_requested = 0;
    state.status = SESSION_STATUS_READY_MASK;
    state.active_session = session;
    state.epoch = 1U;
    assert(direct_frame_session_matches(&state, session));
    assert(!direct_frame_session_matches(&state, 0x55667788U));

    state.status |= SESSION_STATUS_COMMIT_PENDING;
    assert(!direct_frame_session_matches(&state, session));
    state.status = SESSION_STATUS_READY_MASK |
                   SESSION_STATUS_TERMINATION_ACTIVE;
    assert(!direct_frame_session_matches(&state, session));
    state.status = SESSION_STATUS_READY_MASK;
    state.active_session = 0U;
    assert(!direct_frame_session_matches(&state, session));

    puts("PASS: PL-direct TX sends only the metadata session that is live and stable");
    return 0;
}
