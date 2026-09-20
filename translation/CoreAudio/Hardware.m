#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import "AKSupport.h"
#include <dlfcn.h>
#include <math.h>
typedef UInt32 AudioDeviceID;
typedef OSStatus (*HardwareListener)(UInt32,void *);
static _Atomic(UInt32) defaultOutputDevice;
static NSString *outputName(void) {
    AVAudioSession *session=AVAudioSession.sharedInstance; NSError *error=nil;
    if(![session.category isEqualToString:AVAudioSessionCategoryPlayback] || session.sampleRate<=0 || !session.currentRoute.outputs.count)
        if(![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES error:&error])return nil;
    NSArray *outputs=session.currentRoute.outputs;
    return outputs.count?[(AVAudioSessionPortDescription *)outputs.firstObject portName]:nil;
}
static OSStatus copyName(UInt32 capacity,UInt32 *size,void *data) {
    NSString *name=outputName();if(!name)return 'what';
    NSData *bytes=[name dataUsingEncoding:NSUTF8StringEncoding];UInt32 required=(UInt32)bytes.length+1;
    if(size)*size=required;
    if(!size || !data || capacity<required)return '!siz';
    memcpy(data,bytes.bytes,bytes.length);((char *)data)[bytes.length]=0;return 0;
}
static void *native(const char *name) {
    static void *library; static dispatch_once_t once;
    dispatch_once(&once,^{library=dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio",RTLD_NOW|RTLD_LOCAL);});
    return library?dlsym(library,name):NULL;
}
static void report(const char *operation,UInt32 property,OSStatus status,UInt32 size) {
    static unsigned count;
    @synchronized(NSProcessInfo.class) { if(count++>=64)return; }
    AKLogC("audio %s property=%c%c%c%c status=%d size=%u",operation,(property>>24)&255,(property>>16)&255,(property>>8)&255,property&255,(int)status,(unsigned)size);
}
OSStatus AudioHardwareGetPropertyInfo(UInt32 property,UInt32 *size,Boolean *writable) {
    OSStatus (*f)(UInt32,UInt32 *,Boolean *)=native(__func__);
    OSStatus s=f?f(property,size,writable):-4;report(__func__,property,s,s==0&&size?*size:0);return s;
}
OSStatus AudioHardwareGetProperty(UInt32 property,UInt32 *size,void *data) {
    OSStatus (*f)(UInt32,UInt32 *,void *)=native(__func__);
    OSStatus s=f?f(property,size,data):-4;
    if(!s && property=='dOut' && size && *size==sizeof(UInt32) && data) { UInt32 device;memcpy(&device,data,sizeof device);defaultOutputDevice=device;AKLogC("audio default output device=%u",(unsigned)device); }
    report(__func__,property,s,s==0&&size?*size:0);return s;
}
OSStatus AudioHardwareAddPropertyListener(UInt32 property,HardwareListener listener,void *context) {
    OSStatus (*f)(UInt32,HardwareListener,void *)=native(__func__);
    OSStatus s=f?f(property,listener,context):-4;report(__func__,property,s,0);return s;
}
OSStatus AudioDeviceGetPropertyInfo(AudioDeviceID device,UInt32 channel,Boolean input,UInt32 property,UInt32 *size,Boolean *writable) {
    OSStatus (*f)(AudioDeviceID,UInt32,Boolean,UInt32,UInt32 *,Boolean *)=native(__func__);
    OSStatus s=f?f(device,channel,input,property,size,writable):-4;
    if(s && device==defaultOutputDevice && !input && property=='name') { NSString *name=outputName();if(name) { if(size)*size=(UInt32)[name lengthOfBytesUsingEncoding:NSUTF8StringEncoding]+1;if(writable)*writable=false;s=0; } }
    if(device==defaultOutputDevice && !input && (property=='nsrt' || property=='fsz#')) {
        if(size)*size=property=='nsrt'?sizeof(Float64):sizeof(UInt32);
        if(writable)*writable=false;s=0;
    }
    report(__func__,property,s,s==0&&size?*size:0);return s;
}
OSStatus AudioDeviceGetProperty(AudioDeviceID device,UInt32 channel,Boolean input,UInt32 property,UInt32 *size,void *data) {
    OSStatus (*f)(AudioDeviceID,UInt32,Boolean,UInt32,UInt32 *,void *)=native(__func__);
    UInt32 capacity=size?*size:0;OSStatus s=f?f(device,channel,input,property,size,data):-4;
    if(s && device==defaultOutputDevice && !input && property=='name')s=copyName(capacity,size,data);
    if(device==defaultOutputDevice && !input && (property=='nsrt' || property=='fsz#')) {
        // The legacy iOS hardware API may return success with a zero nominal
        // rate. RemoteIO's route comes from the activated audio session.
        NSString *route=outputName();AVAudioSession *session=AVAudioSession.sharedInstance;
        Float64 rate=session.sampleRate;UInt32 frames=(UInt32)llround(rate*session.IOBufferDuration);
        UInt32 required=property=='nsrt'?sizeof rate:sizeof frames;
        if(!route || rate<=0 || (property=='fsz#' && !frames))s='what';
        else if(!size || !data || capacity<required) { if(size)*size=required;s='!siz'; }
        else { memcpy(data,property=='nsrt'?(const void *)&rate:(const void *)&frames,required);*size=required;s=0; }
        AKLogC("audio route nominal_rate=%.0f buffer_frames=%u",rate,(unsigned)frames);
    }
    report(__func__,property,s,s==0&&size?*size:0);return s;
}
OSStatus AudioDeviceSetProperty(AudioDeviceID device,const void *when,UInt32 channel,Boolean input,UInt32 property,UInt32 size,const void *data) {
    OSStatus (*f)(AudioDeviceID,const void *,UInt32,Boolean,UInt32,UInt32,const void *)=native(__func__);
    OSStatus s=f?f(device,when,channel,input,property,size,data):-4;report(__func__,property,s,size);return s;
}
