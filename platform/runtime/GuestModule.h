#pragma once
#import <Foundation/Foundation.h>

// Original executables live only in the writable data container. These routines
// copy/verify bytes; they never load native code, sign it, or change instructions.
BOOL guest_module_import(NSString *source, NSString *root, NSError **error);
// As guest_module_import; returns the stored module's SHA-256 (its directory name).
NSString *guest_module_import_hash(NSString *source, NSString *root, NSError **error);
// SHA-256 of a regular file (symlinks refused); length in *size when non-NULL.
NSString *guest_module_hash(NSString *path, uint64_t *size, NSError **error);
// Verified OriginalExecutable.bin of the stored module with this SHA-256.
NSString *guest_module_path(NSString *root, NSString *sha256, NSError **error);
NSString *guest_module_selected(NSString *root, NSError **error);
