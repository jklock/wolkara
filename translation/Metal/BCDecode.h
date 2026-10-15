// Block-compressed (BC1-BC7, "DXT"/"BPTC") texture decoding on the CPU, for
// GPUs without BC sampling (iPhones before the A17 Pro and other devices whose
// -[MTLDevice supportsBCTextureCompression] is NO). Every Mac GPU samples BC,
// so macOS applications upload BC data unconditionally; BCTextures.m stores
// such textures uncompressed and decodes each upload here. Plain C with no
// Metal dependency, so it is tested on the Mac (tests/test_bc_decode.c).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    AKBCNone = 0,
    AKBC1,      // RGBA8: 4-colour, or 3-colour with punch-through alpha
    AKBC2,      // RGBA8: BC1 colour (always 4-colour) and explicit 4-bit alpha
    AKBC3,      // RGBA8: BC1 colour (always 4-colour) and interpolated alpha
    AKBC4,      // R8 unorm
    AKBC4S,     // R8 snorm
    AKBC5,      // RG8 unorm
    AKBC5S,     // RG8 snorm
    AKBC6H,     // RGBA16 float from unsigned BC6H; alpha 1.0
    AKBC6HS,    // RGBA16 float from signed BC6H; alpha 1.0
    AKBC7,      // RGBA8
} AKBCKind;

// MTLPixelFormat numbers, kept here so this file needs no Metal header
// (tests/test_bc_textures.m checks them against Metal's own constants).
enum {
    AKPixelFormatR8Unorm = 10, AKPixelFormatR8Snorm = 12,
    AKPixelFormatRG8Unorm = 30, AKPixelFormatRG8Snorm = 32,
    AKPixelFormatRGBA8Unorm = 70, AKPixelFormatRGBA8Unorm_sRGB = 71,
    AKPixelFormatRGBA16Float = 115,
    AKPixelFormatBC1_RGBA = 130, AKPixelFormatBC1_RGBA_sRGB = 131,
    AKPixelFormatBC2_RGBA = 132, AKPixelFormatBC2_RGBA_sRGB = 133,
    AKPixelFormatBC3_RGBA = 134, AKPixelFormatBC3_RGBA_sRGB = 135,
    AKPixelFormatBC4_RUnorm = 140, AKPixelFormatBC4_RSnorm = 141,
    AKPixelFormatBC5_RGUnorm = 142, AKPixelFormatBC5_RGSnorm = 143,
    AKPixelFormatBC6H_RGBFloat = 150, AKPixelFormatBC6H_RGBUfloat = 151,
    AKPixelFormatBC7_RGBAUnorm = 152, AKPixelFormatBC7_RGBAUnorm_sRGB = 153,
};

// The kind of a BC MTLPixelFormat, or AKBCNone for any other format.
AKBCKind AKBCKindOfPixelFormat(unsigned long format);
// The uncompressed MTLPixelFormat that stores a BC format's decoded texels
// (sRGB stays sRGB), or 0 for a format that is not BC.
unsigned long AKBCDecodedPixelFormat(unsigned long format);
// Bytes per 4x4 block (8 for BC1 and BC4, 16 otherwise) and bytes per decoded
// texel; both 0 for AKBCNone.
size_t AKBCBlockBytes(AKBCKind kind);
size_t AKBCTexelBytes(AKBCKind kind);

// Decodes one block into a 4x4 texel tile, rowBytes apart.
void AKBCDecodeBlock(AKBCKind kind, const uint8_t *block, uint8_t *texels, size_t rowBytes);

// Decodes the blocks covering a width x height texel rectangle. `blocks` holds
// rows of ceil(width/4) blocks, blockRowBytes apart (Metal's bytesPerRow for a
// compressed format is per row of blocks). Partial edge blocks are clipped:
// exactly width x height texels are written to `texels`, texelRowBytes apart.
// Returns false (and writes nothing) for AKBCNone, a zero size, or row strides
// too small for the rectangle.
bool AKBCDecodeRect(AKBCKind kind, const uint8_t *blocks, size_t blockRowBytes,
                    uint32_t width, uint32_t height, uint8_t *texels, size_t texelRowBytes);
