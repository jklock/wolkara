// Quartz events as Wine's Mac driver reads them: from -[NSEvent CGEvent] (an
// AKQuartzEvent) and from the Core Graphics adapter's own constructors.
#import "AKSupport.h"
#include <assert.h>
typedef CFTypeRef CGEventRef, CGEventSourceRef;
extern CGEventRef CGEventCreate(CGEventSourceRef), CGEventCreateKeyboardEvent(CGEventSourceRef, uint16_t, bool);
extern CGPoint CGEventGetLocation(CGEventRef);
extern void CGEventSetLocation(CGEventRef, CGPoint);
extern uint64_t CGEventGetTimestamp(CGEventRef), CGEventGetFlags(CGEventRef);
extern void CGEventSetFlags(CGEventRef, uint64_t);
extern uint32_t CGEventGetType(CGEventRef);
extern int64_t CGEventGetIntegerValueField(CGEventRef, uint32_t);
extern double CGEventGetDoubleValueField(CGEventRef, uint32_t);
extern void CGEventSetIntegerValueField(CGEventRef, uint32_t, int64_t), CGEventSetDoubleValueField(CGEventRef, uint32_t, double);
extern CGEventSourceRef CGEventCreateSourceFromEvent(CGEventRef);
int main(void) { @autoreleasepool {
    AKQuartzEvent *mouse = [AKQuartzEvent new];
    mouse.type = 1; mouse.location = CGPointMake(12.5, 700); mouse.timestamp = 42; mouse.flags = 1 << 17;
    [mouse setDoubleValueField:4 value:-2.5]; [mouse setIntegerValueField:3 value:1];
    CGEventRef event = (__bridge CGEventRef)mouse;
    assert(CGEventGetType(event) == 1 && CGEventGetTimestamp(event) == 42 && CGEventGetFlags(event) == 1 << 17);
    CGPoint location = CGEventGetLocation(event); assert(location.x == 12.5 && location.y == 700);
    // Fields read as either kind; unset ones are zero.
    assert(CGEventGetDoubleValueField(event, 4) == -2.5 && CGEventGetIntegerValueField(event, 4) == -2);
    assert(CGEventGetIntegerValueField(event, 3) == 1 && CGEventGetDoubleValueField(event, 3) == 1);
    assert(CGEventGetIntegerValueField(event, 88) == 0 && CGEventGetDoubleValueField(event, 97) == 0);
    // Wine's cursor clipping moves events and rewrites their deltas.
    CGEventSetLocation(event, CGPointMake(1, 2)); CGEventSetDoubleValueField(event, 5, 3.25); CGEventSetIntegerValueField(event, 40, 99);
    assert(CGEventGetLocation(event).y == 2 && mouse.location.x == 1 && [mouse doubleValueField:5] == 3.25 && CGEventGetIntegerValueField(event, 40) == 99);
    // No sources; constructors hand out owned events.
    assert(!CGEventCreateSourceFromEvent(event));
    CGEventRef key = CGEventCreateKeyboardEvent(NULL, 0x31, true);
    assert(key && CGEventGetType(key) == 10 && CGEventGetIntegerValueField(key, 9) == 0x31);
    CGEventSetFlags(key, 1 << 20); assert(CGEventGetFlags(key) == 1 << 20);
    CFRelease(key);
    CGEventRef blank = CGEventCreate(NULL); assert(blank && CGEventGetType(blank) == 0 && CGEventGetLocation(blank).x == 0); CFRelease(blank);
    // A null event reads as empty and ignores changes, rather than crashing.
    assert(CGEventGetLocation(NULL).x == 0 && CGEventGetIntegerValueField(NULL, 1) == 0);
    CGEventSetLocation(NULL, CGPointMake(0, 0)); CGEventSetIntegerValueField(NULL, 1, 1);
    puts("quartz events: location, timestamp, flags, typed fields, keyboard events and null events: PASS");
} }
