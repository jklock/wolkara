#import "NibArchive.h"

// Four tables: objects, keys, values, class names.
typedef struct { const uint8_t *bytes; NSUInteger length, offset; bool bad; } AKNibCursor;

static uint64_t nib_varint(AKNibCursor *cursor) {
    uint64_t value = 0;
    for (unsigned shift = 0; shift < 64; shift += 7) {
        if (cursor->offset >= cursor->length) break;
        uint8_t byte = cursor->bytes[cursor->offset++];
        value |= (uint64_t)(byte & 127) << shift;
        if (byte & 128) return value;
    }
    cursor->bad = true; return 0;
}
// A name is stored with its length, zero padded.
static NSString *nib_string(AKNibCursor *cursor, uint64_t length) {
    if (cursor->bad || length > cursor->length - cursor->offset) { cursor->bad = true; return nil; }
    const uint8_t *start = cursor->bytes + cursor->offset;
    cursor->offset += (NSUInteger)length;
    while (length && !start[length - 1]) length--;
    NSString *text = [[NSString alloc] initWithBytes:start length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    if (!text) cursor->bad = true;
    return text;
}
static id nib_value(AKNibCursor *cursor) {
    if (cursor->offset >= cursor->length) { cursor->bad = true; return nil; }
    uint8_t type = cursor->bytes[cursor->offset++];
    if (type == 4) return @YES;
    if (type == 5) return @NO;
    if (type == 9) return NSNull.null;
    if (type == 8) {
        uint64_t size = nib_varint(cursor);
        if (cursor->bad || size > cursor->length - cursor->offset) { cursor->bad = true; return nil; }
        if (!size) return @{@"data":@""};
        // One buffer for the whole blob; nothing per byte.
        static const char digits[] = "0123456789abcdef";
        const uint8_t *at = cursor->bytes + cursor->offset;
        char *hex = malloc((size_t)size * 2);
        if (!hex) { cursor->bad = true; return nil; }
        for (uint64_t i = 0; i < size; i++) {
            hex[2 * i] = digits[at[i] >> 4];
            hex[2 * i + 1] = digits[at[i] & 15];
        }
        cursor->offset += (NSUInteger)size;
        NSString *text = [[NSString alloc] initWithBytesNoCopy:hex length:(NSUInteger)size * 2
                                                      encoding:NSASCIIStringEncoding freeWhenDone:YES];
        if (!text) { free(hex); cursor->bad = true; return nil; }
        return @{@"data":text};
    }
    static const unsigned widths[] = {1, 2, 4, 8, 0, 0, 4, 8, 0, 0, 4};
    if (type >= sizeof widths / sizeof *widths || !widths[type]) { cursor->bad = true; return nil; }
    unsigned width = widths[type];
    if (width > cursor->length - cursor->offset) { cursor->bad = true; return nil; }
    const uint8_t *at = cursor->bytes + cursor->offset;
    cursor->offset += width;
    switch (type) {
    case 0: { int8_t value; memcpy(&value, at, 1); return @((long long)value); }
    case 1: { int16_t value; memcpy(&value, at, 2); return @((long long)value); }
    case 2: { int32_t value; memcpy(&value, at, 4); return @((long long)value); }
    case 3: { int64_t value; memcpy(&value, at, 8); return @(value); }
    case 6: { float value; memcpy(&value, at, 4); return @((double)value); }
    case 7: { double value; memcpy(&value, at, 8); return @(value); }
    // A reference names another object by its place.
    default: { uint32_t value; memcpy(&value, at, 4); return @{@"ref":@((unsigned long long)value)}; }
    }
}

NSDictionary *AKReadNibArchive(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    if (length < 50 || memcmp(bytes, "NIBArchive", 10)) return nil;
    uint32_t header[10];
    memcpy(header, bytes + 10, sizeof header);
    if (header[0] != 1 || (header[1] != 9 && header[1] != 10)) return nil;
    NSMutableArray *tables[4];
    for (unsigned kind = 0; kind < 4; kind++) {
        uint32_t count = header[2 + kind * 2], offset = header[3 + kind * 2];
        if (count > 100000 || offset < 50 || offset > length) return nil;
        AKNibCursor cursor = {bytes, length, offset, false};
        tables[kind] = [NSMutableArray arrayWithCapacity:count];
        for (uint32_t i = 0; i < count; i++) {
            id entry = nil;
            if (!kind) {
                uint64_t triple[3];
                for (unsigned j = 0; j < 3; j++) triple[j] = nib_varint(&cursor);
                entry = @[@(triple[0]), @(triple[1]), @(triple[2])];
            } else if (kind == 1 || kind == 3) {
                uint64_t size = nib_varint(&cursor);
                if (kind == 3) {
                    // A class entry may name the classes it extends.
                    uint64_t extras = nib_varint(&cursor);
                    if (cursor.bad || extras > (cursor.length - cursor.offset) / 4) return nil;
                    cursor.offset += (NSUInteger)(extras * 4);
                }
                entry = nib_string(&cursor, size);
            } else {
                uint64_t key = nib_varint(&cursor);
                id value = cursor.bad ? nil : nib_value(&cursor);
                entry = value ? @[@(key), value] : nil;
            }
            if (cursor.bad || !entry) return nil;
            [tables[kind] addObject:entry];
        }
    }
    NSArray *objects = tables[0], *keys = tables[1], *values = tables[2], *classes = tables[3];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:objects.count];
    for (NSArray *object in objects) {
        uint64_t class_index = [object[0] unsignedLongLongValue];
        uint64_t start = [object[1] unsignedLongLongValue], count = [object[2] unsignedLongLongValue];
        if (class_index >= classes.count || start > values.count || count > values.count - start) return nil;
        NSMutableArray *fields = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
        for (uint64_t i = 0; i < count; i++) {
            NSArray *pair = values[(NSUInteger)(start + i)];
            uint64_t key = [pair[0] unsignedLongLongValue];
            id value = pair[1];
            if (key >= keys.count) return nil;
            if ([value isKindOfClass:NSDictionary.class] && value[@"ref"] &&
                [value[@"ref"] unsignedLongLongValue] >= objects.count) return nil;
            [fields addObject:@[keys[(NSUInteger)key], value]];
        }
        [result addObject:@{@"class":classes[(NSUInteger)class_index], @"values":fields}];
    }
    return @{@"format":@1, @"objects":result};
}
