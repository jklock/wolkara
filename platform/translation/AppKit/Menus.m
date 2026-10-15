#import "AppKit.h"
@implementation NSMenuItem { BOOL _separator; }
- (instancetype)init { return [self initWithTitle:@"" action:NULL keyEquivalent:@""]; }
- (instancetype)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)key {
    if ((self=[super init])) { _title=[title copy]; _action=action; _keyEquivalent=[key copy]; _enabled=YES; }
    return self;
}
+ (instancetype)separatorItem { NSMenuItem *item=[self new]; item->_separator=YES; return item; }
- (BOOL)isSeparatorItem { return _separator; }
@end
@implementation NSMenu { NSMutableArray<NSMenuItem *> *_items; }
- (instancetype)init { return [self initWithTitle:@""]; }
- (instancetype)initWithTitle:(NSString *)title {
    if ((self=[super init])) { _title=[title copy]; _items=[NSMutableArray new]; _autoenablesItems=YES; }
    return self;
}
- (NSArray *)itemArray { return [_items copy]; }
- (NSInteger)numberOfItems { return _items.count; }
- (NSMenuItem *)addItemWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)key { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key]; [self addItem:item]; return item; }
- (void)addItem:(NSMenuItem *)item { if(item) { [_items addObject:item]; item.menu=self; } }
- (void)insertItem:(NSMenuItem *)item atIndex:(NSInteger)index { [_items insertObject:item atIndex:index]; item.menu=self; }
- (void)removeItem:(NSMenuItem *)item { [_items removeObjectIdenticalTo:item]; item.menu=nil; }
- (void)removeItemAtIndex:(NSInteger)index { [self removeItem:_items[index]]; }
- (NSMenuItem *)itemAtIndex:(NSInteger)index { return index>=0 && index<(NSInteger)_items.count ? _items[index] : nil; }
- (NSMenuItem *)itemWithTag:(NSInteger)tag { for(NSMenuItem *item in _items) if(item.tag==tag) return item; return nil; }
- (NSMenuItem *)itemWithTitle:(NSString *)title { for(NSMenuItem *item in _items) if([item.title isEqual:title]) return item; return nil; }
- (NSInteger)indexOfItem:(NSMenuItem *)item { NSUInteger index=[_items indexOfObjectIdenticalTo:item]; return index==NSNotFound?-1:(NSInteger)index; }
- (void)setSubmenu:(NSMenu *)submenu forItem:(NSMenuItem *)item { item.submenu=submenu; }
@end
