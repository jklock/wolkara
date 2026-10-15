#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// A step with its count of parts, when it has one ("… (6,012 of 13,287)").
NSString *_Nullable TKStartupStepText(const char *_Nullable step, unsigned long long done, unsigned long long total);
// The lines shown, from their parts; file is relative to the app's folder, nil
// while nothing was written since the start.
NSString *TKStartupActivityText(NSString *_Nullable step, NSTimeInterval seconds,
                                NSString *_Nullable file, unsigned long long bytes, NSTimeInterval age);
NS_ASSUME_NONNULL_END
