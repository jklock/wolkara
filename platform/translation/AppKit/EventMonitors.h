// NSEvent local monitors, kept apart from UIKit so they can be tested on the Mac.
#pragma once
#import <Foundation/Foundation.h>
typedef id (^AKEventHandler)(id event);
// The returned token is what +[NSEvent removeMonitor:] takes; the handler is copied.
id AKEventMonitorAdd(NSUInteger mask, AKEventHandler handler);
void AKEventMonitorRemove(id token);
// Runs the handlers whose mask includes the event type, oldest first. nil: one consumed it.
id AKEventMonitorRun(id event, NSUInteger type);
