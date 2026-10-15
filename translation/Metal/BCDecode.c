// CPU decoding of BC1-BC7, following the Direct3D 11 block layouts (the same
// formats Metal names BC1_RGBA ... BC7_RGBAUnorm). See BCDecode.h.
#include "BCDecode.h"
#include <string.h>

AKBCKind AKBCKindOfPixelFormat(unsigned long format) {
    switch (format) {
        case AKPixelFormatBC1_RGBA: case AKPixelFormatBC1_RGBA_sRGB: return AKBC1;
        case AKPixelFormatBC2_RGBA: case AKPixelFormatBC2_RGBA_sRGB: return AKBC2;
        case AKPixelFormatBC3_RGBA: case AKPixelFormatBC3_RGBA_sRGB: return AKBC3;
        case AKPixelFormatBC4_RUnorm: return AKBC4;
        case AKPixelFormatBC4_RSnorm: return AKBC4S;
        case AKPixelFormatBC5_RGUnorm: return AKBC5;
        case AKPixelFormatBC5_RGSnorm: return AKBC5S;
        case AKPixelFormatBC6H_RGBUfloat: return AKBC6H;
        case AKPixelFormatBC6H_RGBFloat: return AKBC6HS;
        case AKPixelFormatBC7_RGBAUnorm: case AKPixelFormatBC7_RGBAUnorm_sRGB: return AKBC7;
        default: return AKBCNone;
    }
}

unsigned long AKBCDecodedPixelFormat(unsigned long format) {
    switch (format) {
        case AKPixelFormatBC1_RGBA_sRGB: case AKPixelFormatBC2_RGBA_sRGB:
        case AKPixelFormatBC3_RGBA_sRGB: case AKPixelFormatBC7_RGBAUnorm_sRGB:
            return AKPixelFormatRGBA8Unorm_sRGB;
        default: break;
    }
    switch (AKBCKindOfPixelFormat(format)) {
        case AKBC1: case AKBC2: case AKBC3: case AKBC7: return AKPixelFormatRGBA8Unorm;
        case AKBC4: return AKPixelFormatR8Unorm;
        case AKBC4S: return AKPixelFormatR8Snorm;
        case AKBC5: return AKPixelFormatRG8Unorm;
        case AKBC5S: return AKPixelFormatRG8Snorm;
        case AKBC6H: case AKBC6HS: return AKPixelFormatRGBA16Float;
        case AKBCNone: break;
    }
    return 0;
}

size_t AKBCBlockBytes(AKBCKind kind) {
    switch (kind) {
        case AKBCNone: return 0;
        case AKBC1: case AKBC4: case AKBC4S: return 8;
        default: return 16;
    }
}

size_t AKBCTexelBytes(AKBCKind kind) {
    switch (kind) {
        case AKBCNone: return 0;
        case AKBC4: case AKBC4S: return 1;
        case AKBC5: case AKBC5S: return 2;
        case AKBC6H: case AKBC6HS: return 8;
        default: return 4;
    }
}

static uint64_t load64(const uint8_t *p) {
    uint64_t v = 0;
    for (unsigned i = 0; i < 8; i++) v |= (uint64_t)p[i] << (8 * i);
    return v;
}

// --- BC1-BC5 -----------------------------------------------------------------

// The colour half of BC1, BC2 and BC3. BC2 and BC3 always use four colours;
// BC1 uses three and transparent black when the first endpoint is not greater.
static void decode_color(const uint8_t *block, bool alwaysFourColors, uint8_t out[16][4]) {
    unsigned c0 = block[0] | (unsigned)block[1] << 8, c1 = block[2] | (unsigned)block[3] << 8;
    uint8_t palette[4][4];
    unsigned endpoints[2] = { c0, c1 };
    for (unsigned e = 0; e < 2; e++) {
        unsigned c = endpoints[e], r = c >> 11 & 31, g = c >> 5 & 63, b = c & 31;
        palette[e][0] = (uint8_t)(r << 3 | r >> 2);
        palette[e][1] = (uint8_t)(g << 2 | g >> 4);
        palette[e][2] = (uint8_t)(b << 3 | b >> 2);
        palette[e][3] = 255;
    }
    if (alwaysFourColors || c0 > c1) {
        // Thirds as 21/64 and 43/64, rounded: what Apple GPUs produce.
        for (unsigned ch = 0; ch < 3; ch++) {
            palette[2][ch] = (uint8_t)((43u * palette[0][ch] + 21u * palette[1][ch] + 32) >> 6);
            palette[3][ch] = (uint8_t)((21u * palette[0][ch] + 43u * palette[1][ch] + 32) >> 6);
        }
        palette[2][3] = palette[3][3] = 255;
    } else {
        for (unsigned ch = 0; ch < 3; ch++)
            palette[2][ch] = (uint8_t)((palette[0][ch] + palette[1][ch] + 1) / 2);
        palette[2][3] = 255;
        memset(palette[3], 0, 4);   // punch-through: transparent black
    }
    uint32_t indices = block[4] | (uint32_t)block[5] << 8 | (uint32_t)block[6] << 16 | (uint32_t)block[7] << 24;
    for (unsigned i = 0; i < 16; i++) memcpy(out[i], palette[indices >> (2 * i) & 3], 4);
}

// The 8-byte interpolated channel of BC3 (alpha), BC4 and BC5. Sevenths and
// fifths are taken in 64ths, as Apple GPUs do (they keep the result unrounded;
// it is rounded to the nearest 8-bit value here).
static const uint8_t sevenths[6] = { 9, 18, 27, 37, 46, 55 }, fifths[4] = { 13, 26, 38, 51 };
static void decode_channel(const uint8_t *block, uint8_t out[16]) {
    unsigned a0 = block[0], a1 = block[1];
    uint8_t palette[8] = { (uint8_t)a0, (uint8_t)a1 };
    if (a0 > a1) {
        for (unsigned i = 0; i < 6; i++) palette[i + 2] = (uint8_t)(((64u - sevenths[i]) * a0 + sevenths[i] * a1 + 32) >> 6);
    } else {
        for (unsigned i = 0; i < 4; i++) palette[i + 2] = (uint8_t)(((64u - fifths[i]) * a0 + fifths[i] * a1 + 32) >> 6);
        palette[6] = 0; palette[7] = 255;
    }
    uint64_t indices = load64(block) >> 16;
    for (unsigned i = 0; i < 16; i++) out[i] = palette[indices >> (3 * i) & 7];
}

// Signed: endpoints are two's-complement bytes. Like Apple GPUs, the mode and
// the interpolation use the stored values; only a result below -127 (-128,
// which snorm reads as -1.0 anyway) is clamped.
static int divide_rounded(int value, int divisor) {
    return value >= 0 ? (value + divisor / 2) / divisor : -((-value + divisor / 2) / divisor);
}
static void decode_channel_signed(const uint8_t *block, int8_t out[16]) {
    int a0 = (int8_t)block[0], a1 = (int8_t)block[1];
    int palette[8] = { a0, a1 };
    if (a0 > a1) {
        for (int i = 0; i < 6; i++) palette[i + 2] = divide_rounded((64 - sevenths[i]) * a0 + sevenths[i] * a1, 64);
    } else {
        for (int i = 0; i < 4; i++) palette[i + 2] = divide_rounded((64 - fifths[i]) * a0 + fifths[i] * a1, 64);
        palette[6] = -127; palette[7] = 127;
    }
    for (unsigned i = 0; i < 8; i++) if (palette[i] < -127) palette[i] = -127;
    uint64_t indices = load64(block) >> 16;
    for (unsigned i = 0; i < 16; i++) out[i] = (int8_t)palette[indices >> (3 * i) & 7];
}

// --- BC6H and BC7 shared tables ----------------------------------------------

typedef struct { uint64_t lo, hi; unsigned position; } Bits;
static Bits bits_of(const uint8_t *block) { return (Bits){ load64(block), load64(block + 8), 0 }; }
static unsigned bits_read(Bits *bits, unsigned count) {   // count <= 32
    if (!count) return 0;
    unsigned p = bits->position;
    uint64_t v = p >= 128 ? 0 : p >= 64 ? bits->hi >> (p - 64) : p == 0 ? bits->lo : bits->lo >> p | bits->hi << (64 - p);
    bits->position += count;
    return (unsigned)(v & ((1ull << count) - 1));
}

// Two-subset partitions (bit i: subset of texel i), shared by BC6H (first 32) and BC7.
static const uint16_t partitions2[64] = {
    0xCCCC, 0x8888, 0xEEEE, 0xECC8, 0xC880, 0xFEEC, 0xFEC8, 0xEC80,
    0xC800, 0xFFEC, 0xFE80, 0xE800, 0xFFE8, 0xFF00, 0xFFF0, 0xF000,
    0xF710, 0x008E, 0x7100, 0x08CE, 0x008C, 0x7310, 0x3100, 0x8CCE,
    0x088C, 0x3110, 0x6666, 0x366C, 0x17E8, 0x0FF0, 0x718E, 0x399C,
    0xAAAA, 0xF0F0, 0x5A5A, 0x33CC, 0x3C3C, 0x55AA, 0x9696, 0xA55A,
    0x73CE, 0x13C8, 0x324C, 0x3BDC, 0x6996, 0xC33C, 0x9966, 0x0660,
    0x0272, 0x04E4, 0x4E40, 0x2720, 0xC936, 0x936C, 0x39C6, 0x639C,
    0x9336, 0x9CC6, 0x817E, 0xE718, 0xCCF0, 0x0FCC, 0x7744, 0xEE22,
};
// Three-subset partitions, two bits per texel (texel 0 in the low bits).
#define P3(a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p) \
    ((uint32_t)(a) | (uint32_t)(b) << 2 | (uint32_t)(c) << 4 | (uint32_t)(d) << 6 | \
     (uint32_t)(e) << 8 | (uint32_t)(f) << 10 | (uint32_t)(g) << 12 | (uint32_t)(h) << 14 | \
     (uint32_t)(i) << 16 | (uint32_t)(j) << 18 | (uint32_t)(k) << 20 | (uint32_t)(l) << 22 | \
     (uint32_t)(m) << 24 | (uint32_t)(n) << 26 | (uint32_t)(o) << 28 | (uint32_t)(p) << 30)
static const uint32_t partitions3[64] = {
    P3(0,0,1,1,0,0,1,1,0,2,2,1,2,2,2,2), P3(0,0,0,1,0,0,1,1,2,2,1,1,2,2,2,1),
    P3(0,0,0,0,2,0,0,1,2,2,1,1,2,2,1,1), P3(0,2,2,2,0,0,2,2,0,0,1,1,0,1,1,1),
    P3(0,0,0,0,0,0,0,0,1,1,2,2,1,1,2,2), P3(0,0,1,1,0,0,1,1,0,0,2,2,0,0,2,2),
    P3(0,0,2,2,0,0,2,2,1,1,1,1,1,1,1,1), P3(0,0,1,1,0,0,1,1,2,2,1,1,2,2,1,1),
    P3(0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2), P3(0,0,0,0,1,1,1,1,1,1,1,1,2,2,2,2),
    P3(0,0,0,0,1,1,1,1,2,2,2,2,2,2,2,2), P3(0,0,1,2,0,0,1,2,0,0,1,2,0,0,1,2),
    P3(0,1,1,2,0,1,1,2,0,1,1,2,0,1,1,2), P3(0,1,2,2,0,1,2,2,0,1,2,2,0,1,2,2),
    P3(0,0,1,1,0,1,1,2,1,1,2,2,1,2,2,2), P3(0,0,1,1,2,0,0,1,2,2,0,0,2,2,2,0),
    P3(0,0,0,1,0,0,1,1,0,1,1,2,1,1,2,2), P3(0,1,1,1,0,0,1,1,2,0,0,1,2,2,0,0),
    P3(0,0,0,0,1,1,2,2,1,1,2,2,1,1,2,2), P3(0,0,2,2,0,0,2,2,0,0,2,2,1,1,1,1),
    P3(0,1,1,1,0,1,1,1,0,2,2,2,0,2,2,2), P3(0,0,0,1,0,0,0,1,2,2,2,1,2,2,2,1),
    P3(0,0,0,0,0,0,1,1,0,1,2,2,0,1,2,2), P3(0,0,0,0,1,1,0,0,2,2,1,0,2,2,1,0),
    P3(0,1,2,2,0,1,2,2,0,0,1,1,0,0,0,0), P3(0,0,1,2,0,0,1,2,1,1,2,2,2,2,2,2),
    P3(0,1,1,0,1,2,2,1,1,2,2,1,0,1,1,0), P3(0,0,0,0,0,1,1,0,1,2,2,1,1,2,2,1),
    P3(0,0,2,2,1,1,0,2,1,1,0,2,0,0,2,2), P3(0,1,1,0,0,1,1,0,2,0,0,2,2,2,2,2),
    P3(0,0,1,1,0,1,2,2,0,1,2,2,0,0,1,1), P3(0,0,0,0,2,0,0,0,2,2,1,1,2,2,2,1),
    P3(0,0,0,0,0,0,0,2,1,1,2,2,1,2,2,2), P3(0,2,2,2,0,0,2,2,0,0,1,2,0,0,1,1),
    P3(0,0,1,1,0,0,1,2,0,0,2,2,0,2,2,2), P3(0,1,2,0,0,1,2,0,0,1,2,0,0,1,2,0),
    P3(0,0,0,0,1,1,1,1,2,2,2,2,0,0,0,0), P3(0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0),
    P3(0,1,2,0,2,0,1,2,1,2,0,1,0,1,2,0), P3(0,0,1,1,2,2,0,0,1,1,2,2,0,0,1,1),
    P3(0,0,1,1,1,1,2,2,2,2,0,0,0,0,1,1), P3(0,1,0,1,0,1,0,1,2,2,2,2,2,2,2,2),
    P3(0,0,0,0,0,0,0,0,2,1,2,1,2,1,2,1), P3(0,0,2,2,1,1,2,2,0,0,2,2,1,1,2,2),
    P3(0,0,2,2,0,0,1,1,0,0,2,2,0,0,1,1), P3(0,2,2,0,1,2,2,1,0,2,2,0,1,2,2,1),
    P3(0,1,0,1,2,2,2,2,2,2,2,2,0,1,0,1), P3(0,0,0,0,2,1,2,1,2,1,2,1,2,1,2,1),
    P3(0,1,0,1,0,1,0,1,0,1,0,1,2,2,2,2), P3(0,2,2,2,0,1,1,1,0,2,2,2,0,1,1,1),
    P3(0,0,0,2,1,1,1,2,0,0,0,2,1,1,1,2), P3(0,0,0,0,2,1,1,2,2,1,1,2,2,1,1,2),
    P3(0,2,2,2,0,1,1,1,0,1,1,1,0,2,2,2), P3(0,0,0,2,1,1,1,2,1,1,1,2,0,0,0,2),
    P3(0,1,1,0,0,1,1,0,0,1,1,0,2,2,2,2), P3(0,0,0,0,0,0,0,0,2,1,1,2,2,1,1,2),
    P3(0,1,1,0,0,1,1,0,2,2,2,2,2,2,2,2), P3(0,0,2,2,0,0,1,1,0,0,1,1,0,0,2,2),
    P3(0,0,2,2,1,1,2,2,1,1,2,2,0,0,2,2), P3(0,0,0,0,0,0,0,0,0,0,0,0,2,1,1,2),
    P3(0,0,0,2,0,0,0,1,0,0,0,2,0,0,0,1), P3(0,2,2,2,1,2,2,2,0,2,2,2,1,2,2,2),
    P3(0,1,0,1,2,2,2,2,2,2,2,2,2,2,2,2), P3(0,1,1,1,2,0,1,1,2,2,0,1,2,2,2,0),
};
#undef P3
// Anchor texels (their index has one bit less): of the second subset of a
// two-subset partition, and of the second and third of a three-subset one.
static const uint8_t anchors2[64] = {
    15,15,15,15,15,15,15,15, 15,15,15,15,15,15,15,15,
    15, 2, 8, 2, 2, 8, 8,15,  2, 8, 2, 2, 8, 8, 2, 2,
    15,15, 6, 8, 2, 8,15,15,  2, 8, 2, 2, 2,15,15, 6,
     6, 2, 6, 8,15,15, 2, 2, 15,15,15,15,15, 2, 2,15,
};
static const uint8_t anchors3a[64] = {
     3, 3,15,15, 8, 3,15,15,  8, 8, 6, 6, 6, 5, 3, 3,
     3, 3, 8,15, 3, 3, 6,10,  5, 8, 8, 6, 8, 5,15,15,
     8,15, 3, 5, 6,10, 8,15, 15, 3,15, 5,15,15,15,15,
     3,15, 5, 5, 5, 8, 5,10,  5,10, 8,13,15,12, 3, 3,
};
static const uint8_t anchors3b[64] = {
    15, 8, 8, 3,15,15, 3, 8, 15,15,15,15,15,15,15, 8,
    15, 8,15, 3,15, 8,15, 8,  3,15, 6,10,15,15,10, 8,
    15, 3,15,10,10, 8, 9,10,  6,15, 8,15, 3, 6, 6, 8,
    15, 3,15,15,15,15,15,15, 15,15,15,15, 3,15,15, 8,
};
static const uint8_t weights2[4] = { 0, 21, 43, 64 };
static const uint8_t weights3[8] = { 0, 9, 18, 27, 37, 46, 55, 64 };
static const uint8_t weights4[16] = { 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };
static const uint8_t *weights_for(unsigned bits) { return bits == 2 ? weights2 : bits == 3 ? weights3 : weights4; }

static unsigned subset_of(unsigned subsets, unsigned partition, unsigned texel) {
    if (subsets == 2) return partitions2[partition] >> texel & 1;
    if (subsets == 3) return partitions3[partition] >> (2 * texel) & 3;
    return 0;
}
static bool is_anchor(unsigned subsets, unsigned partition, unsigned texel) {
    if (texel == 0) return true;
    if (subsets == 2) return texel == anchors2[partition];
    if (subsets == 3) return texel == anchors3a[partition] || texel == anchors3b[partition];
    return false;
}

// --- BC7 -----------------------------------------------------------------------

typedef struct { uint8_t subsets, partitionBits, rotationBits, selectorBits, colorBits, alphaBits,
                 endpointPBits, sharedPBits, indexBits, index2Bits; } BC7Mode;
static const BC7Mode bc7Modes[8] = {
    { 3, 4, 0, 0, 4, 0, 1, 0, 3, 0 },
    { 2, 6, 0, 0, 6, 0, 0, 1, 3, 0 },
    { 3, 6, 0, 0, 5, 0, 0, 0, 2, 0 },
    { 2, 6, 0, 0, 7, 0, 1, 0, 2, 0 },
    { 1, 0, 2, 1, 5, 6, 0, 0, 2, 3 },
    { 1, 0, 2, 0, 7, 8, 0, 0, 2, 2 },
    { 1, 0, 0, 0, 7, 7, 1, 0, 4, 0 },
    { 2, 6, 0, 0, 5, 5, 1, 0, 2, 0 },
};

static uint8_t expand_bits(unsigned value, unsigned bits) {
    value <<= 8 - bits;
    return (uint8_t)(value | value >> bits);
}
static uint8_t interpolate8(unsigned a, unsigned b, unsigned weight) {
    return (uint8_t)(((64 - weight) * a + weight * b + 32) >> 6);
}

static void decode_bc7(const uint8_t *block, uint8_t out[16][4]) {
    Bits bits = bits_of(block);
    unsigned mode = 0;
    while (mode < 8 && !bits_read(&bits, 1)) mode++;
    if (mode == 8) { memset(out, 0, 64); return; }   // reserved: transparent black
    const BC7Mode *m = &bc7Modes[mode];
    unsigned partition = bits_read(&bits, m->partitionBits);
    unsigned rotation = bits_read(&bits, m->rotationBits);
    unsigned selector = bits_read(&bits, m->selectorBits);
    unsigned endpoints = 2u * m->subsets;
    unsigned value[6][4] = {{ 0 }};
    for (unsigned ch = 0; ch < 3; ch++)
        for (unsigned e = 0; e < endpoints; e++) value[e][ch] = bits_read(&bits, m->colorBits);
    if (m->alphaBits)
        for (unsigned e = 0; e < endpoints; e++) value[e][3] = bits_read(&bits, m->alphaBits);
    unsigned colorBits = m->colorBits, alphaBits = m->alphaBits;
    if (m->endpointPBits || m->sharedPBits) {
        unsigned p[6];
        if (m->endpointPBits) for (unsigned e = 0; e < endpoints; e++) p[e] = bits_read(&bits, 1);
        else for (unsigned s = 0; s < m->subsets; s++) p[2 * s] = p[2 * s + 1] = bits_read(&bits, 1);
        for (unsigned e = 0; e < endpoints; e++)
            for (unsigned ch = 0; ch < 4; ch++) value[e][ch] = value[e][ch] << 1 | p[e];
        colorBits++;
        if (alphaBits) alphaBits++;
    }
    uint8_t ep[6][4];
    for (unsigned e = 0; e < endpoints; e++) {
        for (unsigned ch = 0; ch < 3; ch++) ep[e][ch] = expand_bits(value[e][ch], colorBits);
        ep[e][3] = alphaBits ? expand_bits(value[e][3], alphaBits) : 255;
    }
    unsigned primary[16], secondary[16] = { 0 };
    for (unsigned i = 0; i < 16; i++)
        primary[i] = bits_read(&bits, m->indexBits - (is_anchor(m->subsets, partition, i) ? 1 : 0));
    if (m->index2Bits)
        for (unsigned i = 0; i < 16; i++) secondary[i] = bits_read(&bits, m->index2Bits - (i == 0 ? 1 : 0));
    for (unsigned i = 0; i < 16; i++) {
        unsigned s = subset_of(m->subsets, partition, i);
        unsigned colorIndex = primary[i], alphaIndex = primary[i];
        unsigned colorIndexBits = m->indexBits, alphaIndexBits = m->indexBits;
        if (m->index2Bits) {
            if (selector) { colorIndex = secondary[i]; colorIndexBits = m->index2Bits; }
            else { alphaIndex = secondary[i]; alphaIndexBits = m->index2Bits; }
        }
        const uint8_t *a = ep[2 * s], *b = ep[2 * s + 1];
        for (unsigned ch = 0; ch < 3; ch++) out[i][ch] = interpolate8(a[ch], b[ch], weights_for(colorIndexBits)[colorIndex]);
        out[i][3] = interpolate8(a[3], b[3], weights_for(alphaIndexBits)[alphaIndex]);
        if (rotation) { uint8_t t = out[i][3]; out[i][3] = out[i][rotation - 1]; out[i][rotation - 1] = t; }
    }
}

// --- BC6H ----------------------------------------------------------------------

// Header fields: endpoint w (A of subset 0), x (B of subset 0), y and z (A and B
// of subset 1), each red, green, blue; then the partition shape.
enum { RW, RX, RY, RZ, GW, GX, GY, GZ, BW, BX, BY, BZ, SHAPE };
// A run of header bits: `count` bits for field `field` starting at bit `lsb`;
// reversed runs put the first bit read at the highest position.
typedef struct { uint8_t field, lsb, count, reversed; } Run;
typedef struct { bool transformed; uint8_t subsets, endpointBits, deltaBits[3]; Run runs[32]; } BC6Mode;
#define R(f, l, c) { f, l, c, 0 }
#define REV(f, l, c) { f, l, c, 1 }
static const BC6Mode bc6Modes[14] = {
    { true, 2, 10, { 5, 5, 5 }, { R(GY,4,1), R(BY,4,1), R(BZ,4,1), R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,5), R(GZ,4,1),
        R(GY,0,4), R(GX,0,5), R(BZ,0,1), R(GZ,0,4), R(BX,0,5), R(BZ,1,1), R(BY,0,4), R(RY,0,5), R(BZ,2,1), R(RZ,0,5),
        R(BZ,3,1), R(SHAPE,0,5) } },
    { true, 2, 7, { 6, 6, 6 }, { R(GY,5,1), R(GZ,4,1), R(GZ,5,1), R(RW,0,7), R(BZ,0,1), R(BZ,1,1), R(BY,4,1), R(GW,0,7),
        R(BY,5,1), R(BZ,2,1), R(GY,4,1), R(BW,0,7), R(BZ,3,1), R(BZ,5,1), R(BZ,4,1), R(RX,0,6), R(GY,0,4), R(GX,0,6),
        R(GZ,0,4), R(BX,0,6), R(BY,0,4), R(RY,0,6), R(RZ,0,6), R(SHAPE,0,5) } },
    { true, 2, 11, { 5, 4, 4 }, { R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,5), R(RW,10,1), R(GY,0,4), R(GX,0,4), R(GW,10,1),
        R(BZ,0,1), R(GZ,0,4), R(BX,0,4), R(BW,10,1), R(BZ,1,1), R(BY,0,4), R(RY,0,5), R(BZ,2,1), R(RZ,0,5), R(BZ,3,1),
        R(SHAPE,0,5) } },
    { true, 2, 11, { 4, 5, 4 }, { R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,4), R(RW,10,1), R(GZ,4,1), R(GY,0,4), R(GX,0,5),
        R(GW,10,1), R(GZ,0,4), R(BX,0,4), R(BW,10,1), R(BZ,1,1), R(BY,0,4), R(RY,0,4), R(BZ,0,1), R(BZ,2,1), R(RZ,0,4),
        R(GY,4,1), R(BZ,3,1), R(SHAPE,0,5) } },
    { true, 2, 11, { 4, 4, 5 }, { R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,4), R(RW,10,1), R(BY,4,1), R(GY,0,4), R(GX,0,4),
        R(GW,10,1), R(BZ,0,1), R(GZ,0,4), R(BX,0,5), R(BW,10,1), R(BY,0,4), R(RY,0,4), R(BZ,1,1), R(BZ,2,1), R(RZ,0,4),
        R(BZ,4,1), R(BZ,3,1), R(SHAPE,0,5) } },
    { true, 2, 9, { 5, 5, 5 }, { R(RW,0,9), R(BY,4,1), R(GW,0,9), R(GY,4,1), R(BW,0,9), R(BZ,4,1), R(RX,0,5), R(GZ,4,1),
        R(GY,0,4), R(GX,0,5), R(BZ,0,1), R(GZ,0,4), R(BX,0,5), R(BZ,1,1), R(BY,0,4), R(RY,0,5), R(BZ,2,1), R(RZ,0,5),
        R(BZ,3,1), R(SHAPE,0,5) } },
    { true, 2, 8, { 6, 5, 5 }, { R(RW,0,8), R(GZ,4,1), R(BY,4,1), R(GW,0,8), R(BZ,2,1), R(GY,4,1), R(BW,0,8), R(BZ,3,1),
        R(BZ,4,1), R(RX,0,6), R(GY,0,4), R(GX,0,5), R(BZ,0,1), R(GZ,0,4), R(BX,0,5), R(BZ,1,1), R(BY,0,4), R(RY,0,6),
        R(RZ,0,6), R(SHAPE,0,5) } },
    { true, 2, 8, { 5, 6, 5 }, { R(RW,0,8), R(BZ,0,1), R(BY,4,1), R(GW,0,8), R(GY,5,1), R(GY,4,1), R(BW,0,8), R(GZ,5,1),
        R(BZ,4,1), R(RX,0,5), R(GZ,4,1), R(GY,0,4), R(GX,0,6), R(GZ,0,4), R(BX,0,5), R(BZ,1,1), R(BY,0,4), R(RY,0,5),
        R(BZ,2,1), R(RZ,0,5), R(BZ,3,1), R(SHAPE,0,5) } },
    { true, 2, 8, { 5, 5, 6 }, { R(RW,0,8), R(BZ,1,1), R(BY,4,1), R(GW,0,8), R(BY,5,1), R(GY,4,1), R(BW,0,8), R(BZ,5,1),
        R(BZ,4,1), R(RX,0,5), R(GZ,4,1), R(GY,0,4), R(GX,0,5), R(BZ,0,1), R(GZ,0,4), R(BX,0,6), R(BY,0,4), R(RY,0,5),
        R(BZ,2,1), R(RZ,0,5), R(BZ,3,1), R(SHAPE,0,5) } },
    { false, 2, 6, { 6, 6, 6 }, { R(RW,0,6), R(GZ,4,1), R(BZ,0,1), R(BZ,1,1), R(BY,4,1), R(GW,0,6), R(GY,5,1), R(BY,5,1),
        R(BZ,2,1), R(GY,4,1), R(BW,0,6), R(GZ,5,1), R(BZ,3,1), R(BZ,5,1), R(BZ,4,1), R(RX,0,6), R(GY,0,4), R(GX,0,6),
        R(GZ,0,4), R(BX,0,6), R(BY,0,4), R(RY,0,6), R(RZ,0,6), R(SHAPE,0,5) } },
    { false, 1, 10, { 10, 10, 10 }, { R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,10), R(GX,0,10), R(BX,0,10) } },
    { true, 1, 11, { 9, 9, 9 }, { R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,9), R(RW,10,1), R(GX,0,9), R(GW,10,1),
        R(BX,0,9), R(BW,10,1) } },
    { true, 1, 12, { 8, 8, 8 }, { R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,8), REV(RW,10,2), R(GX,0,8), REV(GW,10,2),
        R(BX,0,8), REV(BW,10,2) } },
    { true, 1, 16, { 4, 4, 4 }, { R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,4), REV(RW,10,6), R(GX,0,4), REV(GW,10,6),
        R(BX,0,4), REV(BW,10,6) } },
};
#undef R
#undef REV

static int sign_extend(unsigned value, unsigned bits) {
    unsigned mask = bits >= 32 ? ~0u : (1u << bits) - 1;
    value &= mask;
    return (int)(value ^ (1u << (bits - 1))) - (int)(1u << (bits - 1));
}
static int unquantize(int value, unsigned bits, bool isSigned) {
    if (!isSigned) {
        if (bits >= 15) return value;
        if (value == 0) return 0;
        if (value == (1 << bits) - 1) return 0xFFFF;
        return (int)((((unsigned)value << 16) + 0x8000) >> bits);
    }
    if (bits >= 16) return value;
    bool negative = value < 0;
    unsigned magnitude = (unsigned)(negative ? -value : value), result;
    if (magnitude == 0) result = 0;
    else if (magnitude >= (1u << (bits - 1)) - 1) result = 0x7FFF;
    else result = ((magnitude << 15) + 0x4000) >> (bits - 1);
    return negative ? -(int)result : (int)result;
}
static uint16_t finish_half(int value, bool isSigned) {
    if (!isSigned) return (uint16_t)(((unsigned)value * 31) >> 6);
    if (value < 0) return (uint16_t)((((unsigned)-value * 31) >> 5) | 0x8000);
    return (uint16_t)(((unsigned)value * 31) >> 5);
}

static void decode_bc6h(const uint8_t *block, bool isSigned, uint16_t out[16][4]) {
    Bits bits = bits_of(block);
    unsigned code = bits_read(&bits, 2);
    if (code >= 2) code |= bits_read(&bits, 3) << 2;
    int modeIndex;
    switch (code) {
        case 0: modeIndex = 0; break;
        case 1: modeIndex = 1; break;
        case 2: modeIndex = 2; break;
        case 6: modeIndex = 3; break;
        case 10: modeIndex = 4; break;
        case 14: modeIndex = 5; break;
        case 18: modeIndex = 6; break;
        case 22: modeIndex = 7; break;
        case 26: modeIndex = 8; break;
        case 30: modeIndex = 9; break;
        case 3: modeIndex = 10; break;
        case 7: modeIndex = 11; break;
        case 11: modeIndex = 12; break;
        case 15: modeIndex = 13; break;
        default: modeIndex = -1; break;
    }
    if (modeIndex < 0) {   // reserved mode: black, opaque
        for (unsigned i = 0; i < 16; i++) { out[i][0] = out[i][1] = out[i][2] = 0; out[i][3] = 0x3C00; }
        return;
    }
    const BC6Mode *m = &bc6Modes[modeIndex];
    unsigned field[13] = { 0 };
    for (unsigned r = 0; r < 32 && m->runs[r].count; r++) {
        const Run *run = &m->runs[r];
        for (unsigned i = 0; i < run->count; i++) {
            unsigned bit = bits_read(&bits, 1);
            unsigned position = run->reversed ? run->lsb + run->count - 1 - i : run->lsb + i;
            field[run->field] |= bit << position;
        }
    }
    unsigned partition = field[SHAPE];
    unsigned endpoints = 2u * m->subsets, epBits = m->endpointBits;
    int ep[4][3];   // w, x, y, z
    for (unsigned ch = 0; ch < 3; ch++) {
        unsigned base = ch * 4;
        int w = (int)field[base];
        if (isSigned) w = sign_extend((unsigned)w, epBits);
        ep[0][ch] = w;
        for (unsigned e = 1; e < endpoints; e++) {
            unsigned raw = field[base + e];
            int v;
            if (m->transformed) {
                v = sign_extend(raw, m->deltaBits[ch]);
                unsigned sum = ((unsigned)field[base] + (unsigned)v) & ((1u << epBits) - 1);
                v = isSigned ? sign_extend(sum, epBits) : (int)sum;
            } else v = isSigned ? sign_extend(raw, epBits) : (int)raw;
            ep[e][ch] = v;
        }
    }
    for (unsigned e = 0; e < endpoints; e++)
        for (unsigned ch = 0; ch < 3; ch++) ep[e][ch] = unquantize(ep[e][ch], epBits, isSigned);
    unsigned indexBits = m->subsets == 2 ? 3 : 4;
    for (unsigned i = 0; i < 16; i++) {
        unsigned index = bits_read(&bits, indexBits - (is_anchor(m->subsets, partition, i) ? 1 : 0));
        unsigned s = subset_of(m->subsets, partition, i);
        int weight = weights_for(indexBits)[index];
        for (unsigned ch = 0; ch < 3; ch++) {
            int value = ((64 - weight) * ep[2 * s][ch] + weight * ep[2 * s + 1][ch] + 32) >> 6;
            out[i][ch] = finish_half(value, isSigned);
        }
        out[i][3] = 0x3C00;
    }
}

// --- Dispatch ------------------------------------------------------------------

void AKBCDecodeBlock(AKBCKind kind, const uint8_t *block, uint8_t *texels, size_t rowBytes) {
    uint8_t rgba[16][4];
    size_t texelBytes = AKBCTexelBytes(kind);
    uint8_t tile[16 * 8];
    switch (kind) {
        case AKBCNone: return;
        case AKBC1: decode_color(block, false, rgba); memcpy(tile, rgba, 64); break;
        case AKBC2:
            decode_color(block + 8, true, rgba);
            for (unsigned i = 0; i < 16; i++) { unsigned a = block[i / 2] >> (4 * (i & 1)) & 15; rgba[i][3] = (uint8_t)(a * 17); }
            memcpy(tile, rgba, 64); break;
        case AKBC3: {
            uint8_t alpha[16];
            decode_color(block + 8, true, rgba); decode_channel(block, alpha);
            for (unsigned i = 0; i < 16; i++) rgba[i][3] = alpha[i];
            memcpy(tile, rgba, 64); break;
        }
        case AKBC4: decode_channel(block, tile); break;
        case AKBC4S: decode_channel_signed(block, (int8_t *)tile); break;
        case AKBC5: case AKBC5S: {
            uint8_t r[16], g[16];
            if (kind == AKBC5) { decode_channel(block, r); decode_channel(block + 8, g); }
            else { decode_channel_signed(block, (int8_t *)r); decode_channel_signed(block + 8, (int8_t *)g); }
            for (unsigned i = 0; i < 16; i++) { tile[2 * i] = r[i]; tile[2 * i + 1] = g[i]; }
            break;
        }
        case AKBC6H: case AKBC6HS: {
            uint16_t half[16][4];
            decode_bc6h(block, kind == AKBC6HS, half);
            for (unsigned i = 0; i < 16; i++)
                for (unsigned ch = 0; ch < 4; ch++) { tile[8 * i + 2 * ch] = (uint8_t)half[i][ch]; tile[8 * i + 2 * ch + 1] = (uint8_t)(half[i][ch] >> 8); }
            break;
        }
        case AKBC7: decode_bc7(block, rgba); memcpy(tile, rgba, 64); break;
    }
    for (unsigned y = 0; y < 4; y++) memcpy(texels + y * rowBytes, tile + y * 4 * texelBytes, 4 * texelBytes);
}

bool AKBCDecodeRect(AKBCKind kind, const uint8_t *blocks, size_t blockRowBytes,
                    uint32_t width, uint32_t height, uint8_t *texels, size_t texelRowBytes) {
    size_t blockBytes = AKBCBlockBytes(kind), texelBytes = AKBCTexelBytes(kind);
    if (!blockBytes || !width || !height) return false;
    size_t blocksWide = ((size_t)width + 3) / 4, blocksHigh = ((size_t)height + 3) / 4;
    if (blockRowBytes < blocksWide * blockBytes || texelRowBytes < (size_t)width * texelBytes) return false;
    uint8_t tile[4 * 4 * 8];
    for (size_t by = 0; by < blocksHigh; by++) {
        const uint8_t *row = blocks + by * blockRowBytes;
        size_t rows = height - by * 4 < 4 ? height - by * 4 : 4;
        for (size_t bx = 0; bx < blocksWide; bx++) {
            size_t columns = width - bx * 4 < 4 ? width - bx * 4 : 4;
            uint8_t *target = texels + by * 4 * texelRowBytes + bx * 4 * texelBytes;
            if (rows == 4 && columns == 4) { AKBCDecodeBlock(kind, row + bx * blockBytes, target, texelRowBytes); continue; }
            AKBCDecodeBlock(kind, row + bx * blockBytes, tile, 4 * texelBytes);
            for (size_t y = 0; y < rows; y++) memcpy(target + y * texelRowBytes, tile + y * 4 * texelBytes, columns * texelBytes);
        }
    }
    return true;
}
