// The CoreAudio adapter's property API as Wine's Mac audio driver uses it: one
// output device, the session's route, under the legacy default output's ID.
// Run in the simulator (tools/test_translation_sim.sh).
#import <Foundation/Foundation.h>
#import <CoreAudioTypes/CoreAudioTypes.h>
#include <assert.h>
typedef struct { UInt32 mSelector, mScope, mElement; } Address;
extern OSStatus AudioObjectGetPropertyDataSize(UInt32, const Address *, UInt32, const void *, UInt32 *);
extern OSStatus AudioObjectGetPropertyData(UInt32, const Address *, UInt32, const void *, UInt32 *, void *);
extern OSStatus AudioObjectSetPropertyData(UInt32, const Address *, UInt32, const void *, UInt32, const void *);
extern OSStatus AudioHardwareGetProperty(UInt32, UInt32 *, void *);
int main(void) { @autoreleasepool {
    UInt32 legacy = 0, size = sizeof legacy;
    assert(!AudioHardwareGetProperty('dOut', &size, &legacy) && legacy);
    Address devices = {'dev#', 'glob', 0}, fallback = {'dOut', 'glob', 0};
    UInt32 device = 0; size = 0;
    assert(!AudioObjectGetPropertyDataSize(1, &devices, 0, NULL, &size) && size == sizeof device);
    assert(!AudioObjectGetPropertyData(1, &devices, 0, NULL, &size, &device) && device == legacy);
    size = sizeof device; device = 0;
    assert(!AudioObjectGetPropertyData(1, &fallback, 0, NULL, &size, &device) && device == legacy);
    // Output channels, and no input on the output device.
    Address output = {'slay', 'outp', 0}, input = {'slay', 'inpt', 0};
    union { AudioBufferList list; char bytes[64]; } buffers;
    assert(!AudioObjectGetPropertyDataSize(device, &output, 0, NULL, &size) && size <= sizeof buffers);
    assert(!AudioObjectGetPropertyData(device, &output, 0, NULL, &size, &buffers) && buffers.list.mNumberBuffers == 1 && buffers.list.mBuffers[0].mNumberChannels >= 1);
    size = sizeof buffers;
    assert(!AudioObjectGetPropertyData(device, &input, 0, NULL, &size, &buffers) && buffers.list.mNumberBuffers == 0);
    // Name, UID and back, rate, streams, latency; a too small buffer is refused.
    Address name = {'lnam', 'outp', 0}, uid = {'uid ', 'outp', 0}, rate = {'nsrt', 'outp', 0};
    Address streams = {'stm#', 'outp', 0}, latency = {'ltnc', 'outp', 0}, translate = {'uidd', 'glob', 0};
    CFStringRef text = NULL; size = sizeof text;
    assert(!AudioObjectGetPropertyData(device, &name, 0, NULL, &size, &text) && text && CFStringGetLength(text)); CFRelease(text);
    size = sizeof text;
    assert(!AudioObjectGetPropertyData(device, &uid, 0, NULL, &size, &text) && [(__bridge NSString *)text isEqualToString:@"TolkaraOutput"]);
    UInt32 found = 0; size = sizeof found;
    assert(!AudioObjectGetPropertyData(1, &translate, sizeof text, &text, &size, &found) && found == device); CFRelease(text);
    Float64 hz = 0; size = sizeof hz;
    assert(!AudioObjectGetPropertyData(device, &rate, 0, NULL, &size, &hz) && hz > 0);
    size = 99; assert(!AudioObjectGetPropertyDataSize(device, &streams, 0, NULL, &size) && size == 0);
    UInt32 frames = 0; size = sizeof frames; assert(!AudioObjectGetPropertyData(device, &latency, 0, NULL, &size, &frames));
    size = 2; assert(AudioObjectGetPropertyData(device, &rate, 0, NULL, &size, &hz) == '!siz');
    // The user's volume is left alone.
    Address volume = {'volm', 'glob', 0}; Float32 level = 0.25f;
    assert(!AudioObjectSetPropertyData(device, &volume, 0, NULL, sizeof level, &level));
    puts("audio property API: one output device from the session's route, name, UID, rate, streams, latency and volume: PASS");
} }
