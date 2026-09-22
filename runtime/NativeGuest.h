#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
// Development startup diagnostic. Requires debugger publication of a fresh
// runtime arena, and never changes the packaged original executable.
bool ng_initialize(const char *path, const char *frameworks, const char *library_map, FILE *log, bool full_startup);
// Developer service: select our integrated helper before the process's one
// permitted startup. Fails if Local signing was already selected.
bool ng_use_local_authorization(void);
// Local signing: dlopen a page container signed with the user's own identity
// (it carries the guest's final executable pages), validate it against the
// guest, and vm_remap its pages into the arena instead of asking the developer
// service to prepare memory. Call before ng_initialize. On failure, writes a
// reason to error (startup already attempted, Developer service already
// selected, empty or overlong path).
bool ng_use_signed_image(const char *container_path, char *error, size_t error_size);
