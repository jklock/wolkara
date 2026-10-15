#include <stdint.h>
#include <stdio.h>
#include <string.h>
// Carbon encodes POSIX errno values as 100000 + errno. These APIs return
// non-null C strings; the old generated integer-return stub broke error handling.
const char *GetMacOSStatusCommentString(int32_t status) {
    if (status>=100000 && status<101000) return strerror(status-100000);
    switch(status) {
        case 0: return "Call succeeded with no error";
        case -50: return "error in user parameter list";
        case -43: return "File not found";
        case -108: return "Not enough memory";
        default: return "";
    }
}
const char *GetMacOSStatusErrorString(int32_t status) {
    switch(status) {
        case 0: return "noErr";
        case -50: return "paramErr";
        case -43: return "fnfErr";
        case -108: return "memFullErr";
        case 100001: return "EPERM";
        case 100002: return "ENOENT";
        case 100013: return "EACCES";
        default: return "";
    }
}
