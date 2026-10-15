// Test guest: a plain macOS AppKit + Metal app. Built for macOS arm64, then
// run through tools/patch_macho.py exactly like the game binary will be.
// Deliberately exercises: NSApplicationMain-style startup owning the main thread,
// an NSView subclass (guest class with a shim superclass), CAMetalLayer, a TLS
// variable, and a C++-style static initializer.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

static _Thread_local int tls_counter = 41;          // TLV survives exe->dylib?
// Leaf for Local signing probes: no imports and no relocations, so it runs at
// its offset in a remapped page container (tools/probe_signed_file.sh).
__attribute__((used, noinline, visibility("default"))) int tolkara_probe_leaf(void) { return 0x12345678; }
static double start_time;
__attribute__((constructor)) static void init(void) { start_time = CACurrentMediaTime(); }

static NSString *const kShader =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
     "struct V { float4 p [[position]]; float3 c; };\n"
     "vertex V vs(uint i [[vertex_id]], constant float &a [[buffer(0)]]) {\n"
     "  float2 p[3] = {{0,0.7},{-0.7,-0.7},{0.7,-0.7}};\n"
     "  float3 c[3] = {{1,0,0},{0,1,0},{0,0,1}};\n"
     "  float s = sin(a), k = cos(a);\n"
     "  V o; o.p = float4(p[i].x*k - p[i].y*s, p[i].x*s + p[i].y*k, 0, 1); o.c = c[i]; return o; }\n"
     "fragment float4 fs(V v [[stage_in]]) { return float4(v.c, 1); }\n";

@interface GuestView : NSView
@end

@implementation GuestView {
    id<MTLDevice> _dev;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pso;
}
- (instancetype)initWithFrame:(NSRect)r {
    if ((self = [super initWithFrame:r])) {
        self.wantsLayer = YES;
        _dev = MTLCreateSystemDefaultDevice();
        _queue = [_dev newCommandQueue];
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = _dev;
        l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        NSError *err = nil;
        id<MTLLibrary> lib = [_dev newLibraryWithSource:kShader options:nil error:&err];
        if (!lib) NSLog(@"[guest] shader compile failed: %@", err);
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vs"];
        d.fragmentFunction = [lib newFunctionWithName:@"fs"];
        d.colorAttachments[0].pixelFormat = l.pixelFormat;
        _pso = [_dev newRenderPipelineStateWithDescriptor:d error:&err];
        NSLog(@"[guest] device=%@ tls=%d", _dev.name, ++tls_counter);
    }
    return self;
}
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e { NSLog(@"[guest] keyDown code=%d chars=%@ mods=%#lx", e.keyCode, e.characters, (unsigned long)e.modifierFlags); }
- (void)mouseDown:(NSEvent *)e { NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; NSLog(@"[guest] mouseDown %.0f,%.0f", p.x, p.y); }
- (void)mouseMoved:(NSEvent *)e { static int n; if (++n % 60 == 0) NSLog(@"[guest] mouseMoved dx=%.1f dy=%.1f", e.deltaX, e.deltaY); }

- (void)frame:(NSTimer *)t {
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    CGFloat s = self.window.backingScaleFactor ?: 1;
    l.drawableSize = CGSizeMake(self.bounds.size.width * s, self.bounds.size.height * s);
    id<CAMetalDrawable> drawable = [l nextDrawable];
    if (!drawable) return;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.1, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    float angle = (float)(CACurrentMediaTime() - start_time);
    [enc setRenderPipelineState:_pso];
    [enc setVertexBytes:&angle length:sizeof angle atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
    static int frames;
    if (++frames == 1 || frames % 300 == 0) NSLog(@"[guest] frame %d", frames);
}
@end

@interface GuestDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@end

@implementation GuestDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSRect r = NSMakeRect(100, 100, 800, 600);
    self.window = [[NSWindow alloc] initWithContentRect:r
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    GuestView *v = [[GuestView alloc] initWithFrame:r];
    self.window.contentView = v;
    self.window.title = @"TestGuest";
    self.window.acceptsMouseMovedEvents = YES;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:v];
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 target:v selector:@selector(frame:) userInfo:nil repeats:YES];
    NSLog(@"[guest] didFinishLaunching");
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
@end

int main(int argc, const char *argv[]) {
    NSLog(@"[guest] main entered argc=%d argv0=%s", argc, argc ? argv[0] : "(null)");
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        static GuestDelegate *delegate;
        delegate = [GuestDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        [app run];   // never returns on macOS; the shim must cope with that
    }
    return 0;
}
