#pragma once
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, TKLocalServiceResult) {
    TKLocalServiceReady,
    TKLocalServiceUnavailable,
    TKLocalServiceFailed,
};
typedef void (^TKLocalServiceReply)(TKLocalServiceResult result, NSString *report);

// Bounded, sequential retries of pre-authentication connection failures only.
// This coordinator never attaches a debugger or retries memory preparation.
// Public methods run on the main thread; attempt replies may arrive anywhere.
@interface TKLocalServiceRetry : NSObject
- (instancetype)initWithTimeout:(NSTimeInterval)timeout interval:(NSTimeInterval)interval
                        attempt:(void (^)(TKLocalServiceReply))attempt;
- (void)startWithWaiting:(void (^)(void))waiting completion:(void (^)(BOOL, NSString *))completion;
- (void)cancel;
@end
