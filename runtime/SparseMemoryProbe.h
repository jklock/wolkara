#pragma once
#include <stdbool.h>
#include <stdio.h>

// Only our signed fixture executes. The temporary signal handler accepts PCs
// inside that fixture and is removed before this function returns.
bool guest_sparse_memory_probe(FILE *log);
