#pragma once
#import <UIKit/UIKit.h>
#import "AppLibrary.h"

NS_ASSUME_NONNULL_BEGIN

@class TKLibraryViewController;
@protocol TKLibraryViewControllerDelegate <NSObject>
- (void)libraryViewController:(TKLibraryViewController *)controller startApp:(TKApp *)app;
- (void)libraryViewController:(TKLibraryViewController *)controller checkApp:(TKApp *)app;
- (void)libraryViewControllerShowDiagnostics:(TKLibraryViewController *)controller;
- (void)libraryViewControllerShowExecutionMode:(TKLibraryViewController *)controller;
@end

// The home screen: imported applications, started with one tap.
@interface TKLibraryViewController : UITableViewController
- (instancetype)initWithLibrary:(TKAppLibrary *)library;
@property(nonatomic, weak, nullable) id<TKLibraryViewControllerDelegate> delegate;
// Shown above the list, e.g. why no app can start in this session.
@property(nonatomic, copy, nullable) NSString *notice;
// Looks for newly present profile apps, then reloads.
- (void)refresh;
@end

NS_ASSUME_NONNULL_END
