#pragma once
#include <stdbool.h>
#include <stddef.h>
// Small on-device diagnostic of the guest memory operations that native iPadOS
// cannot provide to the original executable. This does not execute guest code.
bool guest_memory_probe(char *error, size_t error_size);
