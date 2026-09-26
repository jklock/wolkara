#include "Session.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    // The caller's session has the screen, and names itself.
    SecuritySessionId id = 0;
    SessionAttributeBits attributes = 0;
    assert(SessionGetInfo(callerSecuritySession, &id, &attributes) == errSessionSuccess);
    assert(id == AKCallerSessionId && (attributes & sessionHasGraphicAccess) && !(attributes & sessionIsRemote));
    assert(SessionGetInfo(id, NULL, NULL) == errSessionSuccess);
    // No other session exists.
    assert(SessionGetInfo(42, &id, &attributes) == errSessionInvalidId);
    puts("PASS: the caller's security session has graphics access");
}
