#pragma once
#include <stdbool.h>
#include <stdio.h>
// Development startup diagnostic. Requires debugger publication of a fresh
// runtime arena, and never changes the packaged original executable.
bool ng_initialize(const char *path, const char *frameworks, const char *library_map, FILE *log, bool full_startup);
// Select our integrated helper before the process's one permitted startup.
bool ng_use_local_authorization(void);
