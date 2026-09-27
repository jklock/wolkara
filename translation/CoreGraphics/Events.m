#import "AKSupport.h"
// Quartz events: the ones AppKit's -[NSEvent CGEvent] hands out, and events
// made here. iPadOS has no event sources or taps; posting one goes nowhere.
typedef CFTypeRef CGEventRef, CGEventSourceRef;
static AKQuartzEvent *quartz(CGEventRef event) { return (__bridge AKQuartzEvent *)event; }
CGEventRef CGEventCreate(CGEventSourceRef source) { (void)source; return CFBridgingRetain([AKQuartzEvent new]); }
CGEventRef CGEventCreateKeyboardEvent(CGEventSourceRef source, uint16_t keycode, bool down) {
    (void)source;
    AKQuartzEvent *event=[AKQuartzEvent new];
    event.type=down ? 10 : 11;   // kCGEventKeyDown, kCGEventKeyUp
    [event setIntegerValueField:9 value:keycode];   // kCGKeyboardEventKeycode
    return CFBridgingRetain(event);
}
CGPoint CGEventGetLocation(CGEventRef event) { return event ? quartz(event).location : (CGPoint){0,0}; }
void CGEventSetLocation(CGEventRef event, CGPoint location) { if(event) quartz(event).location=location; }
uint64_t CGEventGetTimestamp(CGEventRef event) { return event ? quartz(event).timestamp : 0; }
void CGEventSetTimestamp(CGEventRef event, uint64_t timestamp) { if(event) quartz(event).timestamp=timestamp; }
uint64_t CGEventGetFlags(CGEventRef event) { return event ? quartz(event).flags : 0; }
void CGEventSetFlags(CGEventRef event, uint64_t flags) { if(event) quartz(event).flags=flags; }
uint32_t CGEventGetType(CGEventRef event) { return event ? quartz(event).type : 0; }
void CGEventSetType(CGEventRef event, uint32_t type) { if(event) quartz(event).type=type; }
int64_t CGEventGetIntegerValueField(CGEventRef event, uint32_t field) { return event ? [quartz(event) integerValueField:field] : 0; }
double CGEventGetDoubleValueField(CGEventRef event, uint32_t field) { return event ? [quartz(event) doubleValueField:field] : 0; }
void CGEventSetIntegerValueField(CGEventRef event, uint32_t field, int64_t value) { if(event) [quartz(event) setIntegerValueField:field value:value]; }
void CGEventSetDoubleValueField(CGEventRef event, uint32_t field, double value) { if(event) [quartz(event) setDoubleValueField:field value:value]; }
// No sources: callers fall back to their defaults (Wine's ten pixels a line).
CGEventSourceRef CGEventCreateSourceFromEvent(CGEventRef event) { (void)event; return NULL; }
double CGEventSourceGetPixelsPerLine(CGEventSourceRef source) { (void)source; return 10; }
