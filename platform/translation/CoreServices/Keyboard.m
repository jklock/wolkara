#import <Foundation/Foundation.h>
#import "KeyboardLayout.h"

#include "USKeyMap.h"
typedef struct UCKeyboardLayout UCKeyboardLayout;
int32_t UCKeyTranslate(const UCKeyboardLayout *layout, uint16_t key, uint16_t action, uint32_t modifiers,
                      uint32_t keyboardType, uint32_t options, uint32_t *deadState,
                      unsigned long capacity, unsigned long *length, uint16_t *output) {
    (void)keyboardType;
    if (!layout || *(const uint32_t *)layout != AK_KEY_LAYOUT_MAGIC || key >= 128 || action > 3 ||
        !deadState || !length || !output) return -50;
    *length = 0;
    uint16_t c = usKeyMap[modifiers & 31][key];
    uint32_t newDead = 0;
    if ((modifiers & 8) && !(modifiers & (1|16)) && !(options & 1) && action != 3) {
        if (key == 14) newDead = 0x301; if (key == 32) newDead = 0x308;
        if (key == 34) newDead = 0x302; if (key == 45) newDead = 0x303;
        if (key == 50) newDead = 0x300;
    }
    if (newDead && !*deadState) { *deadState = newDead; return 0; }
    uint16_t result[3] = {c}; unsigned long count = c ? 1 : 0;
    if (*deadState && c) {
        uint16_t accent = (uint16_t)*deadState;
        uint16_t pair[2] = {c, accent};
        NSString *composed = [[NSString stringWithCharacters:pair length:2] precomposedStringWithCanonicalMapping];
        if (composed.length == 1) { result[0] = [composed characterAtIndex:0]; count = 1; }
        else { result[0] = accent == 0x301 ? 0xb4 : accent == 0x308 ? 0xa8 : accent == 0x302 ? 0x2c6 : accent == 0x303 ? 0x2dc : '`';
            result[1] = c; count = c == ' ' ? 1 : 2; }
    }
    if (count > capacity) return -25340;
    memcpy(output, result, count * sizeof(uint16_t)); *length = count; *deadState = 0;
    return 0;
}
