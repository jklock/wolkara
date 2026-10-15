#import <Metal/Metal.h>
#import <objc/runtime.h>
#import "AKSupport.h"
static char passList, encoderRecord;
static id<MTLRenderCommandEncoder> (*originalEncoder)(id,SEL,MTLRenderPassDescriptor *);
static void (*originalPipeline)(id,SEL,id<MTLRenderPipelineState>);
static void (*draw3)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger);
static void (*draw4)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger);
static void (*draw5)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger,NSUInteger);
static void (*indexed5)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id<MTLBuffer>,NSUInteger);
static void (*indexed6)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id<MTLBuffer>,NSUInteger,NSUInteger);
static void (*indexed8)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id<MTLBuffer>,NSUInteger,NSUInteger,NSInteger,NSUInteger);
static IMP replace(Class cls,SEL sel,IMP imp) { Method m=class_getInstanceMethod(cls,sel); if(!m)return NULL; IMP old=method_getImplementation(m); class_replaceMethod(cls,sel,imp,method_getTypeEncoding(m));return old; }
static void recordDraw(id encoder,NSUInteger count,NSUInteger instances) { NSMutableDictionary *r=objc_getAssociatedObject(encoder,&encoderRecord); r[@"draws"]=@([r[@"draws"] unsignedLongLongValue]+1);r[@"vertices"]=@([r[@"vertices"] unsignedLongLongValue]+count*instances); }
static void pipeline(id encoder,SEL sel,id<MTLRenderPipelineState> state) { NSMutableDictionary *r=objc_getAssociatedObject(encoder,&encoderRecord); r[@"pipeline"]=state.label ?: @"unlabeled"; originalPipeline(encoder,sel,state); }
static void d3(id e,SEL s,MTLPrimitiveType p,NSUInteger a,NSUInteger n) { recordDraw(e,n,1);draw3(e,s,p,a,n); }
static void d4(id e,SEL s,MTLPrimitiveType p,NSUInteger a,NSUInteger n,NSUInteger i) { recordDraw(e,n,i);draw4(e,s,p,a,n,i); }
static void d5(id e,SEL s,MTLPrimitiveType p,NSUInteger a,NSUInteger n,NSUInteger i,NSUInteger b) { recordDraw(e,n,i);draw5(e,s,p,a,n,i,b); }
static void i5(id e,SEL s,MTLPrimitiveType p,NSUInteger n,MTLIndexType t,id<MTLBuffer> b,NSUInteger o) {recordDraw(e,n,1);indexed5(e,s,p,n,t,b,o);}
static void i6(id e,SEL s,MTLPrimitiveType p,NSUInteger n,MTLIndexType t,id<MTLBuffer> b,NSUInteger o,NSUInteger i) {recordDraw(e,n,i);indexed6(e,s,p,n,t,b,o,i);}
static void i8(id e,SEL s,MTLPrimitiveType p,NSUInteger n,MTLIndexType t,id<MTLBuffer> b,NSUInteger o,NSUInteger i,NSInteger v,NSUInteger base) {recordDraw(e,n,i);indexed8(e,s,p,n,t,b,o,i,v,base);}
static id<MTLRenderCommandEncoder> encoder(id command,SEL selector,MTLRenderPassDescriptor *descriptor) {
    id<MTLRenderCommandEncoder> result=originalEncoder(command,selector,descriptor); if(!result)return result;
    static dispatch_once_t once;dispatch_once(&once,^{
        Class cls=object_getClass(result);
        originalPipeline=(void *)replace(cls,@selector(setRenderPipelineState:),(IMP)pipeline);
        draw3=(void *)replace(cls,@selector(drawPrimitives:vertexStart:vertexCount:),(IMP)d3);
        draw4=(void *)replace(cls,@selector(drawPrimitives:vertexStart:vertexCount:instanceCount:),(IMP)d4);
        draw5=(void *)replace(cls,@selector(drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:),(IMP)d5);
        indexed5=(void *)replace(cls,@selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:),(IMP)i5);
        indexed6=(void *)replace(cls,@selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:),(IMP)i6);
        indexed8=(void *)replace(cls,@selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:),(IMP)i8);
    });
    NSMutableArray *passes=objc_getAssociatedObject(command,&passList);if(!passes){passes=[NSMutableArray new];objc_setAssociatedObject(command,&passList,passes,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    MTLRenderPassColorAttachmentDescriptor *color=descriptor.colorAttachments[0];
    NSMutableDictionary *r=[@{@"size":@[@(color.texture.width),@(color.texture.height)],@"load":@(color.loadAction),@"store":@(color.storeAction),@"clear":@[@(color.clearColor.red),@(color.clearColor.green),@(color.clearColor.blue),@(color.clearColor.alpha)],@"draws":@0} mutableCopy];
    [passes addObject:r]; objc_setAssociatedObject(result,&encoderRecord,r,OBJC_ASSOCIATION_RETAIN_NONATOMIC); return result;
}
NSArray *AKRenderStatsForCommand(id command) { return objc_getAssociatedObject(command,&passList); }
void AKInstallRenderDiagnostics(Class commandClass) { originalEncoder=(void *)replace(commandClass,@selector(renderCommandEncoderWithDescriptor:),(IMP)encoder); }
