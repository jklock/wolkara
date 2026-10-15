#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Delivers a check's text on the main queue; `finished` ends the check.
typedef void (^TKDiagnosticReport)(NSString *text, BOOL finished);

@interface TKDiagnostic : NSObject
+ (instancetype)diagnosticWithTitle:(NSString *)title detail:(nullable NSString *)detail
                                run:(void (^)(TKDiagnosticReport report))run;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy, nullable) NSString *detail;
// Leaves the process unfit for starting an app (loads compatibility libraries,
// may be terminated by the system). Asks first, then ends the session.
@property(nonatomic) BOOL endsSession;
@end

@interface TKDiagnosticSection : NSObject
+ (instancetype)sectionWithTitle:(NSString *)title footer:(nullable NSString *)footer items:(NSArray<TKDiagnostic *> *)items;
@end

// Shows text that may still be arriving, with a Share button for a file.
@interface TKReportViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title file:(nullable NSString *)file;
@property(nonatomic, copy) NSString *text;
@end

// The development and troubleshooting menu, kept apart from the app library.
@interface TKDiagnosticsViewController : UITableViewController
- (instancetype)initWithSections:(NSArray<TKDiagnosticSection *> *)sections;
// Called once before a check that ends the session runs.
@property(nonatomic, copy, nullable) void (^sessionEnding)(void);
// Starts a check as if it had been chosen in the menu.
- (void)runDiagnostic:(TKDiagnostic *)diagnostic;
@end

NS_ASSUME_NONNULL_END
