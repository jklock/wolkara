#pragma once
#import <Foundation/Foundation.h>
#import "HostExecutionProbe.h"

NS_ASSUME_NONNULL_BEGIN

// Development checks shared by the Diagnostics menu and the launch arguments
// used by tools/. Each returns the text the launcher shows and writes the same
// report file under Documents that the launch-argument form always wrote.
// None of them runs application code.

NSString *TKDocumentsPath(NSString *name);

// Background queue. Emulated-memory self-test, then loads `executable` (if
// given) into guest memory without running it. `missing` explains a nil path.
NSString *TKLoaderCheck(NSString *_Nullable executable, NSString *_Nullable missing);
// Background queue. Runs our own test program through the CPU interpreter.
NSString *TKCPUProbeReport(void);
// Background queue. Compiles our own shader fixtures in Documents/LocalShaderProbe.
NSString *TKLocalShaderProbeReport(void);
// Main thread. Maps our own signed pages; no debugger, JIT or app code.
NSString *TKSignedCacheProbeReport(void);
// Main thread, from a run-loop timer callout: pumps the run loop while waiting.
// Loads the Metal compatibility library, so restart before starting an app.
NSString *TKShaderPauseProbeReport(void);
// Main thread. Executes our own two-instruction sample; a code-signing
// rejection can terminate the process. Launch arguments tag the report.
NSString *TKExecutionProbeReport(HPMode mode, NSArray<NSString *> *arguments);

NS_ASSUME_NONNULL_END
