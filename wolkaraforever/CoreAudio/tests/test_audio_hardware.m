// The CoreAudio adapter's property API as Wine's Mac audio driver uses it: the
// session's route, reported under the legacy default output's ID.
//
// This is the platform's test with the host it now needs. Patch 0005 stopped the
// adapter taking the audio session for itself - it asks the app for the game's
// playback lease instead, through dlsym, because the adapter is its own image and
// cannot link against the app's symbol. A plain `simctl spawn` has no app, so the
// platform's version of this test asks for nothing, gets no route, and aborts at
// its first assertion; the rest of the adapter suite then never runs.
//
// So this file takes the lease the way the app does. Everything the adapter must
// answer is asserted exactly as the platform asserts it - the test is not weakened,
// its missing host is supplied.
//
// Run in the simulator (tools/test_translation_sim.sh).
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudioTypes/CoreAudioTypes.h>
#include <assert.h>
typedef struct { UInt32 mSelector, mScope, mElement; } Address;
extern OSStatus AudioObjectGetPropertyDataSize(UInt32, const Address *, UInt32, const void *, UInt32 *);
extern OSStatus AudioObjectGetPropertyData(UInt32, const Address *, UInt32, const void *, UInt32 *, void *);
extern OSStatus AudioObjectSetPropertyData(UInt32, const Address *, UInt32, const void *, UInt32, const void *);
extern OSStatus AudioHardwareGetProperty(UInt32, UInt32 *, void *);

// The host half of patch 0005's contract. Exported, so the adapter's
// dlsym(RTLD_DEFAULT, "TKWolkaraForeverRequestGamePlayback") finds it.
BOOL TKWolkaraForeverRequestGamePlayback(void) {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error]) return NO;
    return [session setActive:YES error:&error];
}

int main(void) { @autoreleasepool {
    // The app asks before it plays; the adapter answers only once it has.
    assert(TKWolkaraForeverRequestGamePlayback());
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
