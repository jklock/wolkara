#import <Foundation/Foundation.h>

// Validate a desktop MTLB and wrap its unchanged AIR for native iOS, so the
// iPad's own Metal compiler builds the pipelines. Legacy containers (AIR 2.0,
// 2.1, 2.3) and current ones (AIR 2.6, 2.7) are accepted. Returns a separate
// immutable object, or nil for malformed/unknown formats.
NSData *AKLocalMetalLibraryData(NSData *original);
