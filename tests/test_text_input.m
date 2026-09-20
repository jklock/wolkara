#import "TextInput.h"
#include <assert.h>
@interface InputClient : NSObject
@property(copy) NSString *text, *command;
@property NSRange range;
@end
@implementation InputClient
- (void)insertText:(id)text replacementRange:(NSRange)range { self.text=text;self.range=range; }
- (void)doCommandBySelector:(SEL)selector { self.command=NSStringFromSelector(selector); }
@end
int main(void) { @autoreleasepool {
    InputClient *client=[InputClient new];
    AKInterpretTextKey(client,@"é",14,1UL<<19);assert([client.text isEqual:@"é"] && client.range.location==NSNotFound && client.range.length==0);
    AKInterpretTextKey(client,@"a",0,1UL<<20);assert([client.command isEqual:@"selectAll:"] && [client.text isEqual:@"é"]);
    AKInterpretTextKey(client,@"\r",36,0);assert([client.command isEqual:@"insertNewline:"]);
    AKInterpretTextKey(client,@"",123,(1UL<<17)|(1UL<<19));assert([client.command isEqual:@"moveWordLeftAndModifySelection:"]);
    AKInterpretTextKey(client,@"",51,0);assert([client.command isEqual:@"deleteBackward:"]);
    AKInterpretTextKey(client,@"password text must not be logged",0,0);assert([client.text hasPrefix:@"password"]);
    puts("text-client ABI, Unicode, commands and replacement ranges: PASS");
} }
