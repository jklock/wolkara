#import "TextInput.h"
#import "AKSupport.h"
void AKInterpretTextKey(id client,NSString *characters,unsigned short keyCode,NSUInteger modifiers) {
    BOOL shift=(modifiers&(1UL<<17))!=0,option=(modifiers&(1UL<<19))!=0;
    BOOL command=(modifiers&(1UL<<20))!=0,control=(modifiers&(1UL<<18))!=0;
    NSString *name=nil;
    switch(keyCode) {
        case 36: case 76: name=@"insertNewline:";break;
        case 48: name=shift?@"insertBacktab:":@"insertTab:";break;
        case 51: name=option?@"deleteWordBackward:":@"deleteBackward:";break;
        case 117: name=option?@"deleteWordForward:":@"deleteForward:";break;
        case 53: name=@"cancelOperation:";break;
        case 123: name=option?@"moveWordLeft:":@"moveLeft:";break;
        case 124: name=option?@"moveWordRight:":@"moveRight:";break;
        case 125: name=@"moveDown:";break;
        case 126: name=@"moveUp:";break;
        case 115: name=@"moveToBeginningOfDocument:";break;
        case 119: name=@"moveToEndOfDocument:";break;
        case 116: name=@"pageUp:";break;
        case 121: name=@"pageDown:";break;
    }
    if(command) {
        switch(keyCode) {
            case 0:name=@"selectAll:";break;case 8:name=@"copy:";break;
            case 9:name=@"paste:";break;case 7:name=@"cut:";break;
            case 6:name=shift?@"redo:":@"undo:";break;
            case 123:name=@"moveToBeginningOfLine:";break;case 124:name=@"moveToEndOfLine:";break;
        }
    }
    if(shift && ([name hasPrefix:@"move"] || [name hasPrefix:@"page"])) name=[[name substringToIndex:name.length-1] stringByAppendingString:@"AndModifySelection:"];
    if(name) {
        SEL dispatch=NSSelectorFromString(@"doCommandBySelector:");
        if([client respondsToSelector:dispatch]) ((void (*)(id,SEL,SEL))[client methodForSelector:dispatch])(client,dispatch,NSSelectorFromString(name));
        return;
    }
    if(!characters.length || command || control) return;
    SEL insert=NSSelectorFromString(@"insertText:replacementRange:");
    if([client respondsToSelector:insert]) ((void (*)(id,SEL,id,NSRange))[client methodForSelector:insert])(client,insert,characters,NSMakeRange(NSNotFound,0));
    else {
        insert=NSSelectorFromString(@"insertText:");
        if([client respondsToSelector:insert]) ((void (*)(id,SEL,id))[client methodForSelector:insert])(client,insert,characters);
    }
}
