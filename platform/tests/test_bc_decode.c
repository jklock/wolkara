// translation/Metal/BCDecode.c against blocks whose texels are worked out by
// hand from the BC layouts, plus the image-level edge cases (partial blocks,
// padded rows, mip chains). tests/test_bc_textures.m checks random blocks of
// every format and mode against the Mac GPU's own decoder.
#include "BCDecode.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void expect_rgba(const uint8_t *texel, unsigned r, unsigned g, unsigned b, unsigned a) {
    if (texel[0] != r || texel[1] != g || texel[2] != b || texel[3] != a) {
        fprintf(stderr, "texel (%u %u %u %u), expected (%u %u %u %u)\n", texel[0], texel[1], texel[2], texel[3], r, g, b, a);
        abort();
    }
}

// Little-endian bit writer for BC6H/BC7 blocks.
typedef struct { uint8_t bytes[16]; unsigned position; } Writer;
static void put(Writer *w, unsigned value, unsigned count) {
    for (unsigned i = 0; i < count; i++, w->position++)
        if (value >> i & 1) w->bytes[w->position / 8] |= (uint8_t)(1u << (w->position % 8));
}

static void test_formats(void) {
    const struct { unsigned long format, decoded; AKBCKind kind; size_t block, texel; } table[] = {
        { 130, 70, AKBC1, 8, 4 }, { 131, 71, AKBC1, 8, 4 }, { 132, 70, AKBC2, 16, 4 }, { 133, 71, AKBC2, 16, 4 },
        { 134, 70, AKBC3, 16, 4 }, { 135, 71, AKBC3, 16, 4 }, { 140, 10, AKBC4, 8, 1 }, { 141, 12, AKBC4S, 8, 1 },
        { 142, 30, AKBC5, 16, 2 }, { 143, 32, AKBC5S, 16, 2 }, { 150, 115, AKBC6HS, 16, 8 }, { 151, 115, AKBC6H, 16, 8 },
        { 152, 70, AKBC7, 16, 4 }, { 153, 71, AKBC7, 16, 4 },
    };
    for (size_t i = 0; i < sizeof table / sizeof *table; i++) {
        assert(AKBCKindOfPixelFormat(table[i].format) == table[i].kind);
        assert(AKBCDecodedPixelFormat(table[i].format) == table[i].decoded);
        assert(AKBCBlockBytes(table[i].kind) == table[i].block);
        assert(AKBCTexelBytes(table[i].kind) == table[i].texel);
    }
    // Neighbours that are not BC: RGBA8, PVRTC (160+), EAC/ETC2 (170+), ASTC (186+).
    const unsigned long others[] = { 0, 70, 71, 115, 129, 136, 139, 144, 149, 154, 160, 170, 180, 186, 204 };
    for (size_t i = 0; i < sizeof others / sizeof *others; i++) {
        assert(AKBCKindOfPixelFormat(others[i]) == AKBCNone);
        assert(AKBCDecodedPixelFormat(others[i]) == 0);
    }
    assert(AKBCBlockBytes(AKBCNone) == 0 && AKBCTexelBytes(AKBCNone) == 0);
}

static void test_bc1(void) {
    uint8_t out[16][4];
    // Four colours (c0 > c1): red to blue, texels 0-3 use indices 0-3.
    const uint8_t four[8] = { 0x00, 0xF8, 0x1F, 0x00, 0xE4, 0xE4, 0xE4, 0xE4 };
    AKBCDecodeBlock(AKBC1, four, &out[0][0], 16);
    expect_rgba(out[0], 255, 0, 0, 255);
    expect_rgba(out[1], 0, 0, 255, 255);
    expect_rgba(out[2], 171, 0, 84, 255);   // 43/64 and 21/64, as Apple GPUs round
    expect_rgba(out[3], 84, 0, 171, 255);
    expect_rgba(out[15], 84, 0, 171, 255);
    // Three colours and punch-through (c0 <= c1): index 3 is transparent black.
    const uint8_t three[8] = { 0x1F, 0x00, 0x00, 0xF8, 0xE4, 0xE4, 0xE4, 0xE4 };
    AKBCDecodeBlock(AKBC1, three, &out[0][0], 16);
    expect_rgba(out[0], 0, 0, 255, 255);
    expect_rgba(out[1], 255, 0, 0, 255);
    expect_rgba(out[2], 128, 0, 128, 255);
    expect_rgba(out[3], 0, 0, 0, 0);
    // Equal endpoints are three-colour mode too.
    const uint8_t equal[8] = { 0x00, 0x80, 0x00, 0x80, 0xFF, 0xFF, 0xFF, 0xFF };
    AKBCDecodeBlock(AKBC1, equal, &out[0][0], 16);
    for (unsigned i = 0; i < 16; i++) expect_rgba(out[i], 0, 0, 0, 0);
    // Endpoint expansion: 5 and 6 bits replicate their high bits.
    const uint8_t grey[8] = { 0x10, 0x84, 0x10, 0x84, 0, 0, 0, 0 };   // r=16 g=32 b=16
    AKBCDecodeBlock(AKBC1, grey, &out[0][0], 16);
    expect_rgba(out[0], 132, 130, 132, 255);
}

static void test_bc2_bc3(void) {
    uint8_t out[16][4];
    // BC2: explicit alpha nibbles 0..15; the colour half never punches through.
    uint8_t bc2[16] = { 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, 0x1F, 0x00, 0x00, 0xF8, 0xE4, 0xE4, 0xE4, 0xE4 };
    AKBCDecodeBlock(AKBC2, bc2, &out[0][0], 16);
    for (unsigned i = 0; i < 16; i++) assert(out[i][3] == i * 17);
    expect_rgba(out[2], 84, 0, 171, 34);    // c0 <= c1 still interpolates four colours
    // BC3: c0 <= c1 is four-colour, never transparent.
    uint8_t bc3[16] = { 255, 0, 0, 0, 0, 0, 0, 0, 0x1F, 0x00, 0x00, 0xF8, 0xE4, 0xE4, 0xE4, 0xE4 };
    // Alpha indices 0..7 in texels 0..7 and again in 8..15.
    uint64_t indices = 0;
    for (unsigned i = 0; i < 16; i++) indices |= (uint64_t)(i & 7) << (3 * i);
    for (unsigned i = 0; i < 6; i++) bc3[2 + i] = (uint8_t)(indices >> (8 * i));
    AKBCDecodeBlock(AKBC3, bc3, &out[0][0], 16);
    const uint8_t sevenStep[8] = { 255, 0, 219, 183, 147, 108, 72, 36 };
    for (unsigned i = 0; i < 16; i++) assert(out[i][3] == sevenStep[i & 7]);
    expect_rgba(out[0], 0, 0, 255, 255);
    expect_rgba(out[3], 171, 0, 84, 183);
    bc3[0] = 0; bc3[1] = 255;   // a0 <= a1: six values plus 0 and 255
    AKBCDecodeBlock(AKBC3, bc3, &out[0][0], 16);
    const uint8_t fiveStep[8] = { 0, 255, 52, 104, 151, 203, 0, 255 };
    for (unsigned i = 0; i < 16; i++) assert(out[i][3] == fiveStep[i & 7]);
}

static void test_bc4_bc5(void) {
    uint8_t out[16], pairs[32];
    uint8_t block[8] = { 255, 0 };
    uint64_t indices = 0;
    for (unsigned i = 0; i < 16; i++) indices |= (uint64_t)(i & 7) << (3 * i);
    for (unsigned i = 0; i < 6; i++) block[2 + i] = (uint8_t)(indices >> (8 * i));
    AKBCDecodeBlock(AKBC4, block, out, 4);
    const uint8_t sevenStep[8] = { 255, 0, 219, 183, 147, 108, 72, 36 };
    for (unsigned i = 0; i < 16; i++) assert(out[i] == sevenStep[i & 7]);
    // Signed: -128 selects the mode as stored and interpolates as -128; results clamp to -127.
    block[0] = 0x80; block[1] = 5;
    AKBCDecodeBlock(AKBC4S, block, out, 4);
    const int8_t signedFive[8] = { -127, 5, -101, -74, -49, -22, -127, 127 };
    for (unsigned i = 0; i < 16; i++) assert((int8_t)out[i] == signedFive[i & 7]);
    block[0] = 0x81; block[1] = 0x80;   // -127 > -128: seven-step, every value clamps to -127
    AKBCDecodeBlock(AKBC4S, block, out, 4);
    for (unsigned i = 0; i < 16; i++) assert((int8_t)out[i] == -127);
    // BC5: red from the first half, green from the second.
    uint8_t bc5[16] = { 255, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0 };
    for (unsigned i = 0; i < 6; i++) bc5[2 + i] = bc5[10 + i] = (uint8_t)(indices >> (8 * i));
    AKBCDecodeBlock(AKBC5, bc5, pairs, 8);
    const uint8_t fiveStep[8] = { 0, 255, 52, 104, 151, 203, 0, 255 };
    for (unsigned i = 0; i < 16; i++) assert(pairs[2 * i] == sevenStep[i & 7] && pairs[2 * i + 1] == fiveStep[i & 7]);
    AKBCDecodeBlock(AKBC5S, bc5, pairs, 8);   // 255 and 0 read as -1 and 0
    assert((int8_t)pairs[0] == -1 && (int8_t)pairs[1] == 0);
}

static void test_bc7(void) {
    uint8_t out[16][4];
    // Mode 6: one subset, 7-bit RGBA endpoints with a p-bit each, 4-bit indices.
    Writer w = { { 0 }, 0 };
    put(&w, 1u << 6, 7);
    for (unsigned ch = 0; ch < 4; ch++) { put(&w, 127, 7); put(&w, 0, 7); }   // endpoint 0 = 254|p, endpoint 1 = 0|p
    put(&w, 1, 1); put(&w, 0, 1);
    put(&w, 0, 3);
    for (unsigned i = 1; i < 16; i++) put(&w, i, 4);
    assert(w.position == 128);
    AKBCDecodeBlock(AKBC7, w.bytes, &out[0][0], 16);
    const uint8_t weights[16] = { 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };
    for (unsigned i = 0; i < 16; i++) {
        unsigned v = ((64 - weights[i]) * 255 + 32) >> 6;
        expect_rgba(out[i], v, v, v, v);
    }
    // Mode 5 with rotation 1: alpha and red trade places after interpolation.
    Writer r = { { 0 }, 0 };
    put(&r, 1u << 5, 6);
    put(&r, 1, 2);                                  // rotation: swap red and alpha
    put(&r, 127, 7); put(&r, 127, 7);               // red 255
    put(&r, 0, 7); put(&r, 0, 7);                   // green 0
    put(&r, 64, 7); put(&r, 64, 7);                 // blue 129
    put(&r, 10, 8); put(&r, 10, 8);                 // alpha 10
    assert(r.position == 66);
    AKBCDecodeBlock(AKBC7, r.bytes, &out[0][0], 16);
    for (unsigned i = 0; i < 16; i++) expect_rgba(out[i], 10, 0, 129, 255);
    // A reserved mode (no mode bit in the first byte) is transparent black.
    uint8_t reserved[16]; memset(reserved, 0xFF, sizeof reserved); reserved[0] = 0;
    AKBCDecodeBlock(AKBC7, reserved, &out[0][0], 16);
    for (unsigned i = 0; i < 16; i++) expect_rgba(out[i], 0, 0, 0, 0);
}

static void test_bc6h(void) {
    uint16_t out[16][4];
    // Mode 11 (code 00011): one region, plain 10-bit endpoints 0 and 1023.
    Writer w = { { 0 }, 0 };
    put(&w, 3, 5);
    put(&w, 0, 30);
    for (unsigned ch = 0; ch < 3; ch++) put(&w, 1023, 10);
    put(&w, 0, 3);
    for (unsigned i = 1; i < 16; i++) put(&w, i, 4);
    assert(w.position == 128);
    AKBCDecodeBlock(AKBC6H, w.bytes, (uint8_t *)out, 32);
    assert(out[0][0] == 0 && out[0][3] == 0x3C00);
    assert(out[15][0] == 0x7BFF && out[15][1] == 0x7BFF && out[15][2] == 0x7BFF);   // 65504, the largest half
    // Weight 34/64 of 0xFFFF, then scaled by 31/64 into half-float bits.
    assert(out[8][0] == (uint16_t)(((((34u * 65535 + 32) >> 6)) * 31) >> 6));
    // Signed: the same endpoints read as 0 and -1 (10-bit two's complement).
    AKBCDecodeBlock(AKBC6HS, w.bytes, (uint8_t *)out, 32);
    assert(out[0][0] == 0 && (out[15][0] & 0x8000) && out[15][3] == 0x3C00);
    // A reserved mode (10011) is opaque black.
    Writer reserved = { { 0 }, 0 };
    put(&reserved, 19, 5);
    AKBCDecodeBlock(AKBC6H, reserved.bytes, (uint8_t *)out, 32);
    for (unsigned i = 0; i < 16; i++) assert(!out[i][0] && !out[i][1] && !out[i][2] && out[i][3] == 0x3C00);
}

// Random blocks, decoded rectangle by rectangle against single blocks.
static uint32_t seed = 12345;
static uint8_t random_byte(void) { seed = seed * 1664525u + 1013904223u; return (uint8_t)(seed >> 24); }

static void test_rect(AKBCKind kind) {
    const size_t blockBytes = AKBCBlockBytes(kind), texelBytes = AKBCTexelBytes(kind);
    // 3x2 blocks, padded rows, for every width 1..12 and height 1..8 (partial edge blocks).
    const size_t blockRow = 3 * blockBytes + 5;
    uint8_t blocks[2 * (3 * 16 + 5)];
    for (size_t i = 0; i < sizeof blocks; i++) blocks[i] = random_byte();
    uint8_t whole[8][12 * 8];
    for (unsigned by = 0; by < 2; by++)
        for (unsigned bx = 0; bx < 3; bx++)
            AKBCDecodeBlock(kind, blocks + by * blockRow + bx * blockBytes, &whole[by * 4][bx * 4 * texelBytes], sizeof whole[0]);
    for (uint32_t width = 1; width <= 12; width++)
        for (uint32_t height = 1; height <= 8; height++) {
            const size_t rowBytes = width * texelBytes + 3;   // padded, and the padding must survive
            uint8_t texels[8 * (12 * 8 + 3) + 16];
            memset(texels, 0xA5, sizeof texels);
            assert(AKBCDecodeRect(kind, blocks, blockRow, width, height, texels, rowBytes));
            for (uint32_t y = 0; y < height; y++) {
                assert(!memcmp(texels + y * rowBytes, whole[y], width * texelBytes));
                for (size_t p = width * texelBytes; p < rowBytes; p++) assert(texels[y * rowBytes + p] == 0xA5);
            }
            for (size_t p = height * rowBytes; p < sizeof texels; p++) assert(texels[p] == 0xA5);
        }
    // Strides too small, empty sizes and non-BC kinds are refused without writing.
    uint8_t texels[4 * 4 * 8] = { 0 };
    assert(!AKBCDecodeRect(kind, blocks, blockBytes - 1, 4, 4, texels, 4 * texelBytes));
    assert(!AKBCDecodeRect(kind, blocks, 2 * blockBytes - 1, 5, 4, texels, 5 * texelBytes));
    assert(!AKBCDecodeRect(kind, blocks, blockBytes, 4, 4, texels, 4 * texelBytes - 1));
    assert(!AKBCDecodeRect(kind, blocks, blockBytes, 0, 4, texels, 0));
    assert(!AKBCDecodeRect(kind, blocks, blockBytes, 4, 0, texels, 16));
    for (size_t i = 0; i < sizeof texels; i++) assert(!texels[i]);
}

// A full mip chain of a 13x7 texture packed one level after another, as a game
// file lays it out: 13x7 (4x2 blocks), 6x3 (2x1), 3x1 (1x1), 1x1 (1x1).
static void test_mip_chain(AKBCKind kind) {
    const size_t blockBytes = AKBCBlockBytes(kind), texelBytes = AKBCTexelBytes(kind);
    const uint32_t sizes[4][2] = { { 13, 7 }, { 6, 3 }, { 3, 1 }, { 1, 1 } };
    size_t offsets[5] = { 0 };
    for (unsigned level = 0; level < 4; level++)
        offsets[level + 1] = offsets[level] + ((sizes[level][0] + 3) / 4) * ((sizes[level][1] + 3) / 4) * blockBytes;
    uint8_t *chain = malloc(offsets[4]);
    for (size_t i = 0; i < offsets[4]; i++) chain[i] = random_byte();
    for (unsigned level = 0; level < 4; level++) {
        uint32_t width = sizes[level][0], height = sizes[level][1];
        size_t blocksWide = (width + 3) / 4, rowBytes = width * texelBytes;
        uint8_t *texels = malloc(rowBytes * height);
        assert(AKBCDecodeRect(kind, chain + offsets[level], blocksWide * blockBytes, width, height, texels, rowBytes));
        for (uint32_t y = 0; y < height; y++)
            for (uint32_t x = 0; x < width; x++) {
                uint8_t tile[4 * 4 * 8];
                AKBCDecodeBlock(kind, chain + offsets[level] + (y / 4 * blocksWide + x / 4) * blockBytes, tile, 4 * texelBytes);
                assert(!memcmp(texels + y * rowBytes + x * texelBytes, tile + (y % 4) * 4 * texelBytes + (x % 4) * texelBytes, texelBytes));
            }
        free(texels);
    }
    free(chain);
}

int main(void) {
    test_formats();
    test_bc1();
    test_bc2_bc3();
    test_bc4_bc5();
    test_bc7();
    test_bc6h();
    const AKBCKind kinds[] = { AKBC1, AKBC2, AKBC3, AKBC4, AKBC4S, AKBC5, AKBC5S, AKBC6H, AKBC6HS, AKBC7 };
    for (size_t i = 0; i < sizeof kinds / sizeof *kinds; i++) { test_rect(kinds[i]); test_mip_chain(kinds[i]); }
    puts("BC1-BC7 decoding: reference blocks, punch-through, signed, partial blocks, padded rows, mip chains: PASS");
    return 0;
}
