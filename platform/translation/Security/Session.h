#pragma once
#include <stdint.h>
#include <MacTypes.h>

// macOS AuthSession.h, which the iPhoneOS SDK does not have.
typedef uint32_t SecuritySessionId;
typedef uint32_t SessionAttributeBits;
enum {
    callerSecuritySession = (SecuritySessionId)-1,
    sessionIsRoot = 0x0001,
    sessionHasGraphicAccess = 0x0010,
    sessionHasTTY = 0x0020,
    sessionIsRemote = 0x1000,
    errSessionSuccess = 0,
    errSessionInvalidId = -60500,
};
// The one session there is.
enum { AKCallerSessionId = 100000 };
OSStatus SessionGetInfo(SecuritySessionId session, SecuritySessionId *session_id, SessionAttributeBits *attributes);
