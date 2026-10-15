#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Loads every shader library the runtime captured under `requests` through the
// on-device rewrap the Metal adapter uses, creates its functions and builds its
// compute pipelines on this device's Metal, and compares the function names
// with a Mac-made translation under `translations` when one exists. Inputs are
// read only; no application code runs. `runID` tags the report.
NSString *TKRunCapturedShaderProbe(NSString *requests, NSString *translations, NSString *_Nullable runID);
NS_ASSUME_NONNULL_END
