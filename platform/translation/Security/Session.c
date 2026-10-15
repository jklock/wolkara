#include "Session.h"

// macOS's Security Server session of the caller. An app on the iPad has the
// screen and a session of its own; programs that draw check for graphics
// access before they start (Wine's Mac driver refuses to without it).
OSStatus SessionGetInfo(SecuritySessionId session, SecuritySessionId *session_id, SessionAttributeBits *attributes) {
    if (session != callerSecuritySession && session != AKCallerSessionId) return errSessionInvalidId;
    if (session_id) *session_id = AKCallerSessionId;
    if (attributes) *attributes = sessionHasGraphicAccess;
    return errSessionSuccess;
}
