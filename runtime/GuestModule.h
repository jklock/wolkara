#pragma once
#import <Foundation/Foundation.h>

// Original executables live only in the writable data container. These routines
// copy/verify bytes; they never load native code, sign it, or change instructions.
BOOL guest_module_import(NSString *source, NSString *root, NSError **error);
NSString *guest_module_selected(NSString *root, NSError **error);
