#import "Diagnostics.h"
#import "CPUProbe.h"
#import "GuestImage.h"
#import "LocalShaderProbe.h"
#import "MemoryProbe.h"
#import "ShaderPauseProbe.h"
#import "SignedCodeProbe.h"
#import <UIKit/UIKit.h>

NSString *TKDocumentsPath(NSString *name) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name];
}

NSString *TKLoaderCheck(NSString *executable, NSString *missing) {
    // Read/allocate away from the UI thread. Never cast a guest VA to a host pointer.
    char error[2048];
    NSString *message;
    if (!guest_memory_probe(error, sizeof error)) {
        message = [NSString stringWithFormat:@"Memory emulation check failed:\n%s", error];
    } else {
        fprintf(stderr, "[softmmu] PASS: MAP_JIT, write protection, fetch, mprotect, fixed remap, munmap\n");
        GuestImage image = {0};
        if (!executable) {
            message=[NSString stringWithFormat:@"Standalone runtime development\n\n%@\n\nThe signed app contains no game executable. Standalone game execution is not integrated yet.",missing?:@"No app selected."];
        } else if (!gi_load(executable.fileSystemRepresentation, &image, error, sizeof error)) {
            message = [NSString stringWithFormat:@"Original guest load failed:\n%s", error];
        } else {
            gi_report(&image, stderr);
            message = [NSString stringWithFormat:
                @"Separate application module verified\nOriginal executable loaded unchanged\n\nGuest memory: %.1f MiB\nInitializers: %llu\nFirst initializer: 0x%llx\n\nMemory emulation checks passed.\n\nStandalone execution is not integrated yet.",
                image.mapped_size / 1048576.0,
                (unsigned long long)image.initializer_count,
                (unsigned long long)image.first_initializer];
            gi_destroy(&image);
        }
    }
    fprintf(stderr, "[host] %s\n", message.UTF8String);
    return message;
}

NSString *TKCPUProbeReport(void) {
    NSString *path=TKDocumentsPath(@"cpu-probe.log");
    FILE *log=fopen(path.fileSystemRepresentation,"w");
    BOOL ok=log && guest_cpu_probe(log,2000000);
    if (log) fclose(log);
    NSString *report=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    fprintf(stderr,"%s",report.UTF8String?:"CPU probe log unavailable.");
    return [NSString stringWithFormat:@"CPU interpreter probe %@\n\n%@",ok?@"passed":@"failed",report?:@""];
}

NSString *TKLocalShaderProbeReport(void) {
    NSString *report=TKRunLocalShaderProbe(TKDocumentsPath(@"LocalShaderProbe"));
    [report writeToFile:TKDocumentsPath(@"local-shader-probe.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return report;
}

NSString *TKSignedCacheProbeReport(void) {
    FILE *log=fopen(TKDocumentsPath(@"signed-code-probe.log").fileSystemRepresentation,"w");
    if(!log) return @"Cannot open signed-code probe log.";
    BOOL ok=HostSignedCodeProbe(log);fclose(log);
    return ok?@"Signed code-cache mapping passed.\nNo debugger or game code used.":@"Signed code-cache mapping unavailable. See probe log.";
}

NSString *TKShaderPauseProbeReport(void) {
    BOOL previousIdleSetting=UIApplication.sharedApplication.idleTimerDisabled;
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    FILE *log=fopen(TKDocumentsPath(@"shader-pause-probe.log").fileSystemRepresentation,"w");
    NSString *result=@"Cannot open shader probe log.";
    if(log) {
        BOOL ok=HostShaderPauseProbe(NSBundle.mainBundle.privateFrameworksPath,log);
        fclose(log);
        result=ok?@"Shader pause and recovery passed.\nNo game code was executed.":@"Shader pause test incomplete. See probe log.";
    }
    UIApplication.sharedApplication.idleTimerDisabled=previousIdleSetting;
    return result;
}

NSString *TKExecutionProbeReport(HPMode mode, NSArray<NSString *> *arguments) {
    BOOL previousIdleSetting = UIApplication.sharedApplication.idleTimerDisabled;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    NSString *logPath = TKDocumentsPath(@"execution-probe.log");
    FILE *log = fopen(logPath.fileSystemRepresentation, "w");
    if (!log) {
        UIApplication.sharedApplication.idleTimerDisabled = previousIdleSetting;
        return @"Cannot open execution probe log.";
    }
    for (NSString *argument in arguments) {
        if ([argument hasPrefix:@"--probe-run-id="]) fprintf(log, "[execution] %s\n", argument.UTF8String);
    }
    HPResult result = host_execution_probe(mode, log);
    UIApplication.sharedApplication.idleTimerDisabled = previousIdleSetting;
    fclose(log);
    NSString *report = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:NULL];
    fprintf(stderr, "%s", report.UTF8String);
    return [NSString stringWithFormat:
        @"Host-generated arm64 execution test\n\nMode: %@\nExecute: %@\nRewrite and execute: %@\n\nAllocation errno: %d\nProtection errno: %d\n\nThis tests host code only. No imported app code has been executed.",
        mode==HP_DUAL_MAPPING ? @"Shared RW / RX views" : mode==HP_READ_WRITE_EXECUTE ? @"RWX" : @"RW → RX", result.executable ? @"PASS" : @"DENIED / FAILED",
        result.rewrite_executable ? @"PASS" : @"DENIED / FAILED",
        result.allocation_errno, result.protection_errno];
}
