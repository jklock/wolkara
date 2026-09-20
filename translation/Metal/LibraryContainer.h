#import <Foundation/Foundation.h>

// Validate a legacy desktop MTLB and wrap its unchanged AIR for native iOS.
// Returns a separate immutable object, or nil for malformed/unknown formats.
NSData *AKLocalMetalLibraryData(NSData *original);
