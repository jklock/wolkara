#pragma once
#include "GuestImage.h"

// Register before guest entry. The placed image must remain mapped for process
// lifetime. Registration reads loader metadata, never executable instructions.
bool ng_unwind_add(const GuestImage *image, uint64_t slide);
// Test-only teardown: no frame or thread may still use a registered image.
bool ng_unwind_reset(void);
