#pragma once
#include <stdint.h>
// Private layout representation shared by our TIS and UCKeyTranslate adapters.
// UIKit supplies composed text; this US layout supplies physical key labels.
#define AK_KEY_LAYOUT_MAGIC 0x414b5553u
static const uint32_t AKUSLayout = AK_KEY_LAYOUT_MAGIC;
