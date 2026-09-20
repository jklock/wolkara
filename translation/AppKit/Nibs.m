#import "AppKit.h"
#import <objc/message.h>

static NSString *nibDirectory;
void AKSetGuestNibDirectory(const char *path) { nibDirectory=path?@(path):nil; }

// The build-time parser produces a faithful data graph from the original nib.
// This instantiator handles the application object and menu graph used at startup.
// Unknown UI classes fail explicitly instead of claiming a successful load.
@interface AKNibGraph : NSObject
@property NSArray<NSDictionary *> *objects;
@property NSMutableDictionary<NSNumber *,id> *instances;
@property id owner;
@property NSUInteger root;
@property BOOL failed;
- (id)object:(NSUInteger)index;
- (id)field:(NSString *)key at:(NSUInteger)index;
@end
@implementation AKNibGraph
- (id)value:(id)value {
    if(value==NSNull.null) return nil;
    if([value isKindOfClass:NSDictionary.class] && value[@"ref"]) return [self object:[value[@"ref"] unsignedIntegerValue]];
    if([value isKindOfClass:NSDictionary.class] && value[@"data"]) {
        NSString *hex=value[@"data"]; NSMutableData *data=[NSMutableData dataWithLength:hex.length/2];
        unsigned char *bytes=data.mutableBytes;
        for(NSUInteger i=0;i<data.length;i++) { unsigned v=0; sscanf([[hex substringWithRange:NSMakeRange(i*2,2)] UTF8String],"%2x",&v); bytes[i]=(unsigned char)v; }
        return data;
    }
    return value;
}
- (id)field:(NSString *)key at:(NSUInteger)index {
    if(index>=self.objects.count) { self.failed=YES; return nil; }
    for(NSArray *pair in self.objects[index][@"values"]) if([pair[0] isEqual:key]) return [self value:pair[1]];
    return nil;
}
- (id)object:(NSUInteger)index {
    if(index>=self.objects.count) { self.failed=YES; return nil; }
    id found=self.instances[@(index)]; if(found) return found==NSNull.null?nil:found;
    if(index==self.root) return self.owner?:NSApp;
    self.instances[@(index)]=NSNull.null;
    NSString *type=self.objects[index][@"class"]; id value=nil;
    if([type isEqual:@"NSString"]) value=[[NSString alloc] initWithData:[self field:@"NS.bytes" at:index] encoding:NSUTF8StringEncoding];
    else if([type isEqual:@"NSNumber"]) value=[self field:@"NS.intval" at:index]?:@0;
    else if([type isEqual:@"NSArray"] || [type isEqual:@"NSMutableArray"] || [type isEqual:@"NSMutableSet"]) {
        NSMutableArray *array=[NSMutableArray new]; self.instances[@(index)]=array;
        for(NSArray *pair in self.objects[index][@"values"]) if([pair[0] isEqual:@"UINibEncoderEmptyKey"]) {
            id item=[self value:pair[1]]; if(item) [array addObject:item];
        }
        value=array;
    } else if([type isEqual:@"IBClassReference"]) value=[self field:@"IBClassName" at:index];
    else if([type isEqual:@"NSCustomObject"]) {
        NSString *name=[self field:@"IBClassReference" at:index]?:[self field:@"NSClassName" at:index];
        Class cls=NSClassFromString(name);
        if(!cls) { AKLog(@"Nib class unavailable: %@",name); self.failed=YES; }
        else if([cls isSubclassOfClass:NSApplication.class]) {
            value=[cls sharedApplication];
            if(![value isKindOfClass:cls]) { AKLog(@"Nib application class mismatch: %@ vs %@",name,[value class]); self.failed=YES; }
        } else value=[cls new];
        AKLog(@"Nib instantiated %@",name);
    } else if([type isEqual:@"NSMenu"]) {
        NSMenu *menu=[[NSMenu alloc] initWithTitle:[self field:@"NSTitle" at:index]?:@""];
        self.instances[@(index)]=menu;
        for(NSMenuItem *item in [self field:@"NSMenuItems" at:index]) [menu addItem:item];
        if([[self field:@"NSName" at:index] isEqual:@"_NSMainMenu"]) NSApp.mainMenu=menu;
        value=menu;
    } else if([type isEqual:@"NSMenuItem"]) {
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:[self field:@"NSTitle" at:index]?:@"" action:NULL keyEquivalent:[self field:@"NSKeyEquiv" at:index]?:@""];
        self.instances[@(index)]=item;
        item.enabled=![[self field:@"NSIsDisabled" at:index] boolValue];
        item.keyEquivalentModifierMask=[[self field:@"NSKeyEquivModMask" at:index] unsignedIntegerValue];
        item.tag=[[self field:@"NSTag" at:index] integerValue];
        item.submenu=[self field:@"NSSubmenu" at:index];
        NSString *action=[self field:@"NSAction" at:index]; if(action) item.action=NSSelectorFromString(action);
        item.target=[self field:@"NSTarget" at:index]; value=item;
    } else if([type isEqual:@"NSNibControlConnector"] || [type isEqual:@"NSNibOutletConnector"]) {
        // Connections are applied after graph instantiation.
        value=@(index);
    } else { AKLog(@"Unsupported nib object class %@",type); self.failed=YES; }
    self.instances[@(index)]=value?:NSNull.null;
    return value;
}
@end

@interface NSBundle (AKNibLoading)
- (BOOL)loadNibNamed:(NSString *)name owner:(id)owner topLevelObjects:(NSArray * __autoreleasing *)objects;
@end
@implementation NSBundle (AKNibLoading)
- (BOOL)loadNibNamed:(NSString *)name owner:(id)owner topLevelObjects:(NSArray * __autoreleasing *)output {
    AKLog(@"loadNibNamed:%@ owner:%@",name,owner?[owner class]:nil);
    NSString *file=[[nibDirectory stringByAppendingPathComponent:name.lastPathComponent] stringByAppendingPathExtension:@"nib.json"];
    NSData *data=[NSData dataWithContentsOfFile:file];
    NSDictionary *archive=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    NSArray *records=archive[@"objects"];
    if([archive[@"format"] intValue]!=1 || ![records isKindOfClass:NSArray.class] || records.count>100000) { AKLog(@"Cannot load translated nib %@",file); return NO; }
    AKNibGraph *graph=[AKNibGraph new]; graph.objects=records; graph.instances=[NSMutableDictionary new]; graph.owner=owner; graph.root=NSNotFound;
    NSUInteger metadata=NSNotFound;
    for(NSUInteger i=0;i<records.count;i++) if([records[i][@"class"] isEqual:@"NSIBObjectData"]) { metadata=i; break; }
    if(metadata==NSNotFound) return NO;
    for(NSArray *pair in records[metadata][@"values"]) if([pair[0] isEqual:@"NSRoot"]) graph.root=[pair[1][@"ref"] unsignedIntegerValue];
    NSArray *top=[graph field:@"NSObjectsKeys" at:metadata];
    NSArray *connections=[graph field:@"NSConnections" at:metadata];
    for(NSNumber *connection in connections) {
        NSUInteger index=connection.unsignedIntegerValue;
        id source=[graph field:@"NSSource" at:index], destination=[graph field:@"NSDestination" at:index];
        NSString *label=[graph field:@"NSLabel" at:index];
        if([records[index][@"class"] isEqual:@"NSNibControlConnector"] && [source isKindOfClass:NSMenuItem.class]) {
            ((NSMenuItem *)source).target=destination; ((NSMenuItem *)source).action=NSSelectorFromString(label);
        } else if(source && label) [source setValue:destination forKey:label];
    }
    if(graph.failed) return NO;
    // Retain graph objects before callbacks; application delegates may store only weak references.
    static NSMutableArray *loaded; if(!loaded) loaded=[NSMutableArray new]; [loaded addObject:graph];
    for(id object in top) if([object respondsToSelector:@selector(awakeFromNib)]) ((void (*)(id,SEL))objc_msgSend)(object,@selector(awakeFromNib));
    if(output) *output=top;
    AKLog(@"Translated nib %@: %lu top-level objects",name,(unsigned long)top.count);
    return YES;
}
@end
