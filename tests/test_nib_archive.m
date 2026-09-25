// What the in-app reader makes of a nib, for comparison.
#import "NibArchive.h"
#include <stdio.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: test_nib_archive <nib>\n"); return 2; }
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        if (!data) { fprintf(stderr, "cannot read %s\n", argv[1]); return 2; }
        NSDictionary *archive = AKReadNibArchive(data);
        if (!archive) { fprintf(stderr, "not a NIBArchive this reader understands\n"); return 1; }
        NSData *json = [NSJSONSerialization dataWithJSONObject:archive options:NSJSONWritingPrettyPrinted error:NULL];
        if (!json) { fprintf(stderr, "the graph cannot be written out\n"); return 1; }
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
