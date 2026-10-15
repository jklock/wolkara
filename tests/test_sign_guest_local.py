"""Tests for tools/sign_guest_local (the codesign-less Mach-O signer).

Self-contained: setUpModule compiles the tool with ASan/UBSan and builds its
own fixtures (tiny arm64 iOS and macOS dylibs and executables, synthetic
Mach-O files, an internal-function harness) in a temporary directory. Covers
the Mach-O parser's rejection paths (it will later consume untrusted guest
binaries on-device), --verify tamper and structure cases (an embedded
Info.plist, escaping of attacker-controlled names), the ad-hoc mode
(byte-identical to codesign -s -, codesign -v --strict, macOS dlopen) and
RSA/ECDSA self-signed signing.

The default run never touches the keychain. Tests that sign with a real
identity run only with TOLKARA_SIGN_KEYCHAIN_TESTS=1 (identity SIGN_IDENTITY,
default "Apple Development", restricted to DEVELOPMENT_TEAM when set); they
may show a keychain approval dialog.

    python3 -m unittest tests.test_sign_guest_local -v
"""

import base64
import hashlib
import os
import re
import shutil
import struct
import subprocess
import tempfile
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, 'tools', 'sign_guest_local.m')
KEYCHAIN_TESTS = os.environ.get('TOLKARA_SIGN_KEYCHAIN_TESTS') == '1'
XCODE = '/Applications/Xcode.app/Contents/Developer'
PAGE = 0x4000
CODE = b'\x20\x00\x80\xd2\xc0\x03\x5f\xd6'  # mov x0, #1; ret
ADHOC_ID = 'sgl.adhoc.test'
SHA256_ALG = b'\x30\x0d\x06\x09\x60\x86\x48\x01\x65\x03\x04\x02\x01\x05\x00'      # AlgorithmIdentifier
RSA_SHA256_ALG = b'\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0b\x05\x00'  # sha256WithRSAEncryption
INFO_PLIST = b'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleIdentifier</key>
\t<string>sgl.plist.test</string>
</dict>
</plist>
'''

ENV = dict(os.environ)
if 'DEVELOPER_DIR' not in ENV and os.path.isdir(XCODE):
    ENV['DEVELOPER_DIR'] = XCODE  # iOS SDK; the Command Line Tools have none
RUN_ENV = dict(ENV, UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')

FIXTURE_C = r'''
#ifdef WITH_BSS
static char big[65536];
#endif
__attribute__((visibility("default"))) int guest_test(void) {
#ifdef WITH_BSS
    big[1] = 1;
    return 0x12345678 + big[7];
#else
    return 0x12345678;
#endif
}
#ifdef WITH_MAIN
#include <stdio.h>
int main(void) { printf("0x%x\n", guest_test()); return 7; }
#endif
'''

HOST_C = r'''
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    void *h = argc > 1 ? dlopen(argv[1], RTLD_NOW) : NULL;
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 2; }
    int (*f)(void) = (int (*)(void))dlsym(h, "guest_test");
    if (!f) { printf("dlsym failed\n"); return 3; }
    printf("guest_test returned 0x%x\n", f());
    return 0;
}
'''

# Internal functions, compiled against the tool source with -DSGL_NO_MAIN.
HARNESS_M = r'''
#include "sign_guest_local.m"

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); \
                                              printf("\n"); failures++; } } while (0)

static NSData *hex(const char *s) {
    NSMutableData *d = [NSMutableData data];
    for (; *s; s++) {
        if (*s == ' ') continue;
        unsigned v;
        sscanf(s, "%2x", &v);
        uint8_t b = (uint8_t)v;
        [d appendBytes:&b length:1];
        s++;
    }
    return d;
}

// One element spanning exactly the buffer, parsed from an exact-size heap
// copy so ASan catches any overread.
static bool tlv_one(NSData *d, bool ber) {
    uint8_t *b = malloc(d.length ? d.length : 1);
    memcpy(b, d.bytes, d.length);
    const uint8_t *p = b, *c, *tlv;
    uint8_t tag;
    size_t cl, tl;
    bool ok = ber ? sgl_ber_tlv(&p, b + d.length, 0, &tag, &c, &cl)
                  : sgl_der_tlv(&p, b + d.length, &tag, &c, &cl, &tlv, &tl);
    ok = ok && p == b + d.length;
    free(b);
    return ok;
}

static SecKeyRef new_key(bool ec, int bits) {
    NSDictionary *params = @{
        (__bridge id)kSecAttrKeyType: ec ? (__bridge id)kSecAttrKeyTypeECSECPrimeRandom : (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeySizeInBits: @(bits),
        (__bridge id)kSecAttrIsPermanent: @NO,
    };
    return SecKeyCreateRandomKey((__bridge CFDictionaryRef)params, NULL);
}

static NSData *cert(NSData *subject, SecKeyRef subjectKey, NSData *issuer, SecKeyRef issuerKey, uint64_t serial,
                    double fromDays, double toDays, int kind) {
    SecKeyRef pub = SecKeyCopyPublicKey(subjectKey);
    NSData *d = sgl_make_certificate(subject, pub, issuer, issuerKey, serial,
                                     [NSDate dateWithTimeIntervalSinceNow:fromDays * 86400],
                                     [NSDate dateWithTimeIntervalSinceNow:toDays * 86400], kind);
    CFRelease(pub);
    return d;
}

static void test_der(void) {
    CHECK(tlv_one(hex("3000"), false), "empty SEQUENCE");
    NSMutableData *long128 = [hex("048180") mutableCopy];
    [long128 increaseLengthBy:128];
    CHECK(tlv_one(long128, false), "long form 0x81 0x80");
    NSMutableData *padded = [hex("04820080") mutableCopy];
    [padded increaseLengthBy:128];
    CHECK(!tlv_one(padded, false), "long form with a leading zero");
    CHECK(!tlv_one(hex("30800000"), false), "indefinite length in DER");
    CHECK(!tlv_one(hex("3085010000000000"), false), "five length bytes");
    CHECK(!tlv_one(hex("3084ffffffff"), false), "length 0xffffffff");
    CHECK(!tlv_one(hex("0481050102030405"), false), "non-minimal long form");
    CHECK(!tlv_one(hex("1f0100"), false), "high tag number");
    CHECK(!tlv_one(hex("30"), false), "truncated header");
    CHECK(!tlv_one(hex("300500"), false), "content past end");
    NSData *parent = hex("3003040500");
    sgl_buf in = sgl_buf_from_data(parent), c, x;
    CHECK(sgl_der_next(&in, 0x30, &c, NULL) && !sgl_der_next(&c, 0x04, &x, NULL), "child longer than parent");

    SecKeyRef k = new_key(true, 256);
    NSData *name = sgl_name_der(@"Apple Development: DER (TEAMDER001)", @"TEAMDER001");
    NSData *good = cert(name, k, name, k, 7, -1, 30, SGL_CERT_CODE_SIGNING);
    sgl_cert_info ci;
    CHECK(good && sgl_parse_certificate(good, &ci) && ci.codeSigning && ci.selfSigned &&
          [ci.subjectOU isEqual:@"TEAMDER001"], "self-made certificate parses");
    for (NSUInteger n = 0; n < good.length; n++)
        CHECK(!sgl_parse_certificate([good subdataWithRange:NSMakeRange(0, n)], &ci), "prefix %lu accepted",
              (unsigned long)n);
    srand(1);
    for (int i = 0; i < 4000; i++) { // mutations must never crash or overread (ASan)
        NSMutableData *m = [good mutableCopy];
        ((uint8_t *)m.mutableBytes)[rand() % m.length] = (uint8_t)rand();
        (void)sgl_parse_certificate(m, &ci);
    }
    CFRelease(k);
}

static void test_ber(void) {
    CHECK(tlv_one(hex("3080 040100 0000"), true), "indefinite SEQUENCE");
    CHECK(tlv_one(hex("3080 a080 0000 0000"), true), "nested indefinite");
    CHECK(tlv_one(hex("3003 040100"), true), "definite element");
    CHECK(!tlv_one(hex("3080 040100"), true), "missing end-of-contents");
    CHECK(!tlv_one(hex("0480 0000"), true), "indefinite primitive");
    CHECK(!tlv_one(hex("3081 03 040100"), true), "non-minimal definite length");
    NSMutableData *nest = [NSMutableData data], *deep = [NSMutableData data];
    for (int i = 0; i < 10; i++) [nest appendData:hex("3080")];
    for (int i = 0; i < 10; i++) [nest appendData:hex("0000")];
    CHECK(tlv_one(nest, true), "10 nested indefinite levels");
    for (int i = 0; i < 5000; i++) [deep appendData:hex("3080")];
    for (int i = 0; i < 5000; i++) [deep appendData:hex("0000")];
    CHECK(!tlv_one(deep, true), "nesting depth is bounded");
}

static void test_derint(void) {
    CHECK([sgl_der_int(0) isEqual:hex("020100")], "0");
    CHECK([sgl_der_int(0x7f) isEqual:hex("02017f")], "0x7f");
    CHECK([sgl_der_int(0x80) isEqual:hex("02020080")], "0x80");
    CHECK([sgl_der_int(0x0102030405060708) isEqual:hex("02080102030405060708")], "8 bytes");
    CHECK([sgl_der_int(UINT64_MAX) isEqual:hex("020900ffffffffffffffff")], "UINT64_MAX");
}

static void test_ecbound(void) {
    CHECK(sgl_signature_bound(YES, 256) == 256, "RSA bound is the block size");
    const int bits[3] = { 256, 384, 521 };
    const size_t want[3] = { 72, 104, 141 };
    for (int i = 0; i < 3; i++) {
        sgl_signer s = {0};
        s.key = new_key(true, bits[i]);
        sgl_signer_key_setup(&s);
        CHECK(s.sigLen == want[i], "P-%d bound %zu", bits[i], s.sigLen);
        for (int j = 0; j < 64; j++) {
            NSData *msg = [[NSString stringWithFormat:@"message %d", j] dataUsingEncoding:NSUTF8StringEncoding];
            NSData *sig = CFBridgingRelease(SecKeyCreateSignature(s.key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                                                  (__bridge CFDataRef)msg, NULL));
            CHECK(sig && sig.length <= s.sigLen, "P-%d signature of %lu bytes", bits[i], (unsigned long)sig.length);
        }
        sgl_signer_release(&s);
    }
}

static void test_identity(void) {
    SecKeyRef k = new_key(true, 256);
    __block uint64_t serial = 100;
    NSData *(^mk)(NSString *, NSString *, double, double, int) = ^NSData *(NSString *cn, NSString *ou, double from,
                                                                            double to, int kind) {
        NSData *n = sgl_name_der(cn, ou);
        return cert(n, k, n, k, serial++, from, to, kind);
    };
    NSString *cnA = @"Apple Development: Test A (TEAMAAAA01)", *cnB = @"Apple Development: Test B (TEAMBBBB02)";
    NSData *a = mk(cnA, @"TEAMAAAA01", -1, 365, SGL_CERT_CODE_SIGNING);
    NSData *b = mk(cnB, @"TEAMBBBB02", -1, 365, SGL_CERT_CODE_SIGNING);
    NSData *aOld = mk(cnA, @"TEAMAAAA01", -700, -1, SGL_CERT_CODE_SIGNING);
    NSData *aFuture = mk(cnA, @"TEAMAAAA01", 1, 365, SGL_CERT_CODE_SIGNING);
    NSData *push = mk(@"Apple Development IOS Push Services: test", @"TEAMAAAA01", -1, 365, SGL_CERT_NO_EKU);
    NSData *exact = mk(@"Apple Development: Exact", @"TEAMEXACT1", -1, 365, SGL_CERT_CODE_SIGNING);
    NSData *exactTwo = mk(@"Apple Development: Exact Two", @"TEAMEXACT1", -1, 365, SGL_CERT_CODE_SIGNING);
    NSArray *all = @[ aOld, push, a, b, aFuture, a ]; // `a` twice: one certificate in two keychains
    NSDate *now = [NSDate date];
    NSString *err = nil;
    NSInteger i = sgl_select_identity(all, @"Apple Development", nil, now, &err);
    CHECK(i == -1 && [err containsString:@"ambiguous"] && [err containsString:cnA] && [err containsString:cnB],
          "two teams are ambiguous: %ld %s", (long)i, err.UTF8String);
    i = sgl_select_identity(all, @"Apple Development", @"TEAMAAAA01", now, &err);
    CHECK(i == 2, "team filter picks the valid certificate, not expired/future ones: %ld %s", (long)i, err.UTF8String);
    i = sgl_select_identity(all, @"Apple Development", @"TEAMCCCC03", now, &err);
    CHECK(i == -1 && [err containsString:@"no valid code-signing identity"], "unknown team");
    i = sgl_select_identity(@[ aOld, aFuture ], @"Test A", nil, now, &err);
    CHECK(i == -1 && [err containsString:@"expired"], "expired/not-yet-valid only: %s", err.UTF8String);
    NSString *fp = sgl_hex(sgl_sha1(b)).uppercaseString;
    CHECK(sgl_select_identity(all, fp, nil, now, &err) == 3, "SHA-1 selection");
    CHECK(sgl_select_identity(all, fp.lowercaseString, nil, now, &err) == 3, "lower-case SHA-1 selection");
    CHECK(sgl_select_identity(all, cnB, nil, now, &err) == 3, "exact CN");
    CHECK(sgl_select_identity(@[ push ], @"Apple Development", nil, now, &err) == -1, "no code-signing EKU");
    CHECK(sgl_select_identity(@[ exactTwo, exact ], @"Apple Development: Exact", nil, now, &err) == 1,
          "an exact CN wins over a substring");
    CHECK(sgl_select_identity(@[ exactTwo, exact ], @"Exact", nil, now, &err) == -1, "substring of two is ambiguous");
    CFRelease(k);
}

static void test_chain(void) {
    SecKeyRef rootKey = new_key(true, 256), interKey = new_key(false, 2048), leafKey = new_key(true, 256);
    SecKeyRef decoyKey = new_key(true, 256), otherRootKey = new_key(true, 256);
    NSData *rootName = sgl_name_der(@"Test Root CA", nil);
    NSData *interName = sgl_name_der(@"Test Developer Relations Certification Authority", @"G9");
    NSData *leafName = sgl_name_der(@"Apple Development: Chain (TEAMCHAIN1)", @"TEAMCHAIN1");
    NSData *root = cert(rootName, rootKey, rootName, rootKey, 1, -1, 3650, SGL_CERT_CA);
    NSData *inter = cert(interName, interKey, rootName, rootKey, 2, -1, 1800, SGL_CERT_CA);
    NSData *interExpired = cert(interName, interKey, rootName, rootKey, 3, -900, -1, SGL_CERT_CA);
    NSData *interDecoy = cert(interName, decoyKey, rootName, rootKey, 4, -1, 1800, SGL_CERT_CA);
    NSData *otherRoot = cert(rootName, otherRootKey, rootName, otherRootKey, 5, -1, 3650, SGL_CERT_CA);
    NSData *leaf = cert(leafName, leafKey, interName, interKey, 6, -1, 365, SGL_CERT_CODE_SIGNING);
    NSDate *now = [NSDate date];
    NSString *err = nil;
    NSArray *chain = sgl_select_chain(leaf, @[ interDecoy, interExpired, otherRoot, root, inter ], now, &err);
    CHECK([chain isEqual:(@[ inter, root, leaf ])], "issuer picked by subject, validity and signature");
    chain = sgl_select_chain(leaf, @[ interDecoy, interExpired, root ], now, &err);
    CHECK(!chain && [err containsString:@"intermediate CA certificate (WWDR)"], "missing intermediate fails");
    CHECK([sgl_select_chain(leaf, @[ inter ], now, &err) isEqual:(@[ inter, leaf ])], "root is optional");
    CHECK(!sgl_select_chain(leaf, @[ root ], now, &err), "a root is not an intermediate");
    CHECK([sgl_select_chain(leaf, @[ otherRoot, inter ], now, &err) isEqual:(@[ inter, leaf ])],
          "a root with the right name but another key is not used");
    sgl_cert_info li;
    CHECK(sgl_parse_certificate(leaf, &li) && sgl_cert_issued_by(&li, inter) && !sgl_cert_issued_by(&li, interDecoy),
          "signature check");
    SecKeyRef keys[5] = { rootKey, interKey, leafKey, decoyKey, otherRootKey };
    for (int i = 0; i < 5; i++) CFRelease(keys[i]);
}

static void test_ident(void) {
    NSString *good[] = { @"a", @"com.example.app", @"sgl-fixture", @"A_b.c-9", [@"" stringByPaddingToLength:128
                         withString:@"x" startingAtIndex:0] };
    NSString *bad[] = { @"", @"-a", @".a", @"_a", @"a b", @"a/b", @"a\nb", @"a\tb", @"café",
                        [@"" stringByPaddingToLength:129 withString:@"x" startingAtIndex:0] };
    for (unsigned i = 0; i < sizeof(good) / sizeof(good[0]); i++)
        CHECK(sgl_valid_identifier(good[i]), "valid %s", good[i].UTF8String);
    for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
        CHECK(!sgl_valid_identifier(bad[i]), "invalid #%u", i);
}

static void test_time(void) {
    struct tm t2049 = { .tm_year = 149, .tm_mon = 11, .tm_mday = 31, .tm_hour = 23, .tm_min = 59, .tm_sec = 59 };
    struct tm t1950 = { .tm_year = 50, .tm_mon = 0, .tm_mday = 1 };
    struct tm t2050 = { .tm_year = 150, .tm_mon = 0, .tm_mday = 1 };
    CHECK([sgl_der_time(0x17, (const uint8_t *)"491231235959Z", 13) timeIntervalSince1970] == timegm(&t2049), "UTCTime 2049");
    CHECK([sgl_der_time(0x17, (const uint8_t *)"500101000000Z", 13) timeIntervalSince1970] == timegm(&t1950), "UTCTime 1950");
    CHECK([sgl_der_time(0x18, (const uint8_t *)"20500101000000Z", 15) timeIntervalSince1970] == timegm(&t2050),
          "GeneralizedTime 2050");
    CHECK(!sgl_der_time(0x17, (const uint8_t *)"4912312359Z", 11), "no seconds");
    CHECK(!sgl_der_time(0x17, (const uint8_t *)"491331000000Z", 13), "month 13");
    CHECK(!sgl_der_time(0x17, (const uint8_t *)"49123123595aZ", 13), "non-digit");
    CHECK(!sgl_der_time(0x17, (const uint8_t *)"4912312359590", 13), "no Z");
    CHECK(!sgl_der_time(0x04, (const uint8_t *)"491231235959Z", 13), "wrong tag");
    struct tm t2060 = { .tm_year = 160, .tm_mon = 0, .tm_mday = 2 };
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:timegm(&t2060)];
    NSData *enc = sgl_der_time_enc(d);
    const uint8_t *p = enc.bytes;
    CHECK(enc.length == 17 && p[0] == 0x18 && [sgl_der_time(p[0], p + 2, p[1]) isEqual:d], "2060 round trip");
}

// sgl_verify_cms on a CMS built here for a stand-in CodeDirectory, signed by
// an ephemeral RSA key. "noou": the signer certificate has no OU, so a team in
// the CodeDirectory is unbacked; "evil": its CN (300+ bytes) and OU carry
// control characters, a backslash and non-ASCII, and the OU does not back the
// team; "dupcert": the signer certificate is embedded twice (fatal: exits 1).
static void test_cms(const char *which) {
    sgl_signer s = sgl_ephemeral_signer(NO);
    NSData *cd = [@"CodeDirectory stand-in" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *certs = s.certs;
    NSData *issuer = s.issuerTLV, *serial = s.serialTLV;
    bool unbacked = !strcmp(which, "noou") || !strcmp(which, "evil");
    if (unbacked) {
        NSString *cn = @"Apple Development: no OU", *ou = nil;
        if (!strcmp(which, "evil")) {
            cn = [[NSString stringWithUTF8String:"Apple Development: \\x0a\n\x1b[31m\xc3\xa9"]
                     stringByPaddingToLength:320 withString:@"A" startingAtIndex:0];
            ou = [NSString stringWithUTF8String:"SELFTEST00\n\x1b[0m"];
        }
        NSData *name = sgl_name_der(cn, ou);
        NSData *leaf = cert(name, s.key, name, s.key, 9, -1, 30, SGL_CERT_CODE_SIGNING);
        sgl_cert_info ci;
        CHECK(leaf && sgl_parse_certificate(leaf, &ci) && [ci.subjectCN isEqual:cn] &&
              (ou ? [ci.subjectOU isEqual:ou] : !ci.subjectOU), "%s certificate", which);
        certs = @[ leaf ];
        issuer = ci.issuerTLV;
        serial = ci.serialTLV;
    } else if (!strcmp(which, "dupcert")) {
        certs = @[ s.certs[0], s.certs[0] ];
    }
    NSData *attrs = sgl_signed_attrs_content(sgl_sha256(cd), @"250101000000Z");
    NSData *sig = CFBridgingRelease(SecKeyCreateSignature(s.key, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
                                                          (__bridge CFDataRef)sgl_der(0x31, attrs), NULL));
    NSData *cms = sgl_build_cms(certs, issuer, serial, attrs, sig, YES);
    NSMutableData *blob = [NSMutableData data];
    sgl_be32(blob, SGL_MAGIC_BLOBWRAPPER);
    sgl_be32(blob, (uint32_t)cms.length + 8);
    [blob appendData:cms];
    int withTeam = sgl_verify_cms(sgl_buf_from_data(blob), cd, s.team);
    int noTeam = sgl_verify_cms(sgl_buf_from_data(blob), cd, nil);
    CHECK(withTeam == (unbacked ? 1 : 0) && noTeam == 0, "%s: %d / %d failures", which, withTeam, noTeam);
    sgl_signer_release(&s);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *g = argc > 1 ? argv[1] : "";
        if (!strcmp(g, "cms")) test_cms(argc > 2 ? argv[2] : "");
        else if (!strcmp(g, "atomic")) sgl_write_atomic([NSData data], @""); // must fail before creating a file
        else if (!strcmp(g, "der")) test_der();
        else if (!strcmp(g, "ber")) test_ber();
        else if (!strcmp(g, "derint")) test_derint();
        else if (!strcmp(g, "ecbound")) test_ecbound();
        else if (!strcmp(g, "identity")) test_identity();
        else if (!strcmp(g, "chain")) test_chain();
        else if (!strcmp(g, "ident")) test_ident();
        else if (!strcmp(g, "time")) test_time();
        else { printf("unknown group %s\n", g); return 2; }
        printf("%s: %d failures\n", g, failures);
        return failures ? 1 : 0;
    }
}
'''

B = None  # build products, set up once per module


def run(args, timeout=300, **kw):
    return subprocess.run(args, capture_output=True, text=True, env=ENV, timeout=timeout, **kw)


def build(args):
    r = run(['xcrun', 'clang', *args])
    if r.returncode != 0:
        raise RuntimeError('build failed: %s\n%s' % (' '.join(args), r.stderr))


def setUpModule():
    global B
    tmp = tempfile.mkdtemp(prefix='sgl-test-')
    try:
        B = types.SimpleNamespace(dir=tmp)
        p = lambda name: os.path.join(tmp, name)
        B.tool, B.harness = p('sign_guest_local'), p('sgl_internal')
        objc = ['-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-O1', '-g', '-fsanitize=address,undefined',
                '-fno-omit-frame-pointer', '-framework', 'Foundation', '-framework', 'Security']
        build([*objc, SOURCE, '-o', B.tool])
        with open(p('harness.m'), 'w') as f:
            f.write(HARNESS_M)
        build([*objc, '-Wno-unused-function', '-DSGL_NO_MAIN', '-I', os.path.dirname(SOURCE), p('harness.m'),
               '-o', B.harness])
        with open(p('fixture.c'), 'w') as f:
            f.write(FIXTURE_C)
        with open(p('host.c'), 'w') as f:
            f.write(HOST_C)
        sdk = run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'])
        # Without an iOS SDK the "iOS" fixtures are macOS ones: the signer is
        # platform-agnostic.
        ios = (['-target', 'arm64-apple-ios17.0', '-isysroot', sdk.stdout.strip()] if sdk.returncode == 0
               else ['-target', 'arm64-apple-macos14.0'])
        mac = ['-target', 'arm64-apple-macos14.0']
        dylib = ['-arch', 'arm64', '-dynamiclib', '-fno-stack-protector', '-Wl,-no_adhoc_codesign', p('fixture.c')]
        os.makedirs(p('fixtures'))
        B.ios_dylib = p('fixtures/sgl-fixture.dylib')  # default identifier: sgl-fixture
        B.ios_bss = p('fixtures/sgl-bss.dylib')        # zerofill __DATA: __LINKEDIT vmaddr != fileoff
        B.ios_exe = p('fixtures/sgl-exe')              # MH_EXECUTE with __PAGEZERO
        B.mac_dylib = p('fixtures/sgl-mac.dylib')
        B.mac_exe = p('fixtures/sgl-mac-exe')
        B.host = p('dlopen-host')
        build([*ios, *dylib, '-o', B.ios_dylib])
        build([*ios, *dylib, '-DWITH_BSS', '-o', B.ios_bss])
        build([*ios, '-arch', 'arm64', '-nostdlib', '-static', '-fno-stack-protector', '-Wl,-no_adhoc_codesign',
               '-Wl,-e,_guest_test', p('fixture.c'), '-o', B.ios_exe])
        build([*mac, *dylib, '-o', B.mac_dylib])
        build([*mac, '-arch', 'arm64', '-DWITH_MAIN', '-Wl,-no_adhoc_codesign', p('fixture.c'), '-o', B.mac_exe])
        build([*mac, '-arch', 'arm64', p('host.c'), '-o', B.host])
        # Signed baselines for the --verify mutation tests.
        B.rsa_path, B.adhoc_path = p('rsa-signed.dylib'), p('adhoc-signed.dylib')
        for args in (['--selftest', B.ios_dylib, B.rsa_path], ['--adhoc', B.ios_dylib, B.adhoc_path]):
            r = subprocess.run([B.tool, *args], capture_output=True, text=True, env=RUN_ENV, timeout=120)
            if r.returncode != 0:
                raise RuntimeError('baseline signing failed: %s' % r.stderr)
        B.rsa = read(B.rsa_path)
        B.adhoc = read(B.adhoc_path)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


def tearDownModule():
    if B is not None:
        shutil.rmtree(B.dir, ignore_errors=True)


def read(path):
    with open(path, 'rb') as f:
        return f.read()


# ---- Mach-O helpers ------------------------------------------------------

def seg(name, vmaddr, vmsize, fileoff, filesize, sects=(), nsects=None):
    name = name if isinstance(name, bytes) else name.encode()
    return struct.pack('<II16sQQQQiiII', 0x19, 72 + 80 * len(sects), name, vmaddr, vmsize, fileoff,
                       filesize, 5, 5, len(sects) if nsects is None else nsects, 0) + b''.join(sects)


def sect(name, segname, offset, size=8, flags=0x80000400):
    return struct.pack('<16s16sQQIIIIIIII', name.encode(), segname.encode(), offset, size, offset, 2, 0, 0, flags,
                       0, 0, 0)


def linkedit_data(cmd, off, size):
    return struct.pack('<IIII', cmd, 16, off, size)


def macho(cmds, length, filetype=6, cputype=0x0100000C, code=()):
    blob = b''.join(cmds)
    d = bytearray(max(length, 32 + len(blob)))
    struct.pack_into('<IIIIIIII', d, 0, 0xFEEDFACF, cputype, 0, filetype, len(cmds), len(blob), 0, 0)
    d[32:32 + len(blob)] = blob
    for off in code:
        d[off:off + len(CODE)] = CODE
    return bytes(d)


def text(sect_off=0x3000, vmsize=PAGE, filesize=PAGE):
    return seg('__TEXT', 0, vmsize, 0, filesize, [sect('__text', '__TEXT', sect_off)])


def linkedit(fileoff=PAGE, filesize=0x40, vmaddr=None, vmsize=PAGE):
    return seg('__LINKEDIT', fileoff if vmaddr is None else vmaddr, vmsize, fileoff, filesize)


def valid(sect_off=0x3000, extra=(), code=True):
    """Minimal signable dylib: __TEXT [0, 16K) with __text, __LINKEDIT to EOF."""
    return macho([text(sect_off), linkedit(), *extra], PAGE + 0x40, code=[sect_off] if code else [])


def load_commands(d):
    ncmds, sizeofcmds = struct.unpack_from('<II', d, 16)
    off, out = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, off)
        out.append((cmd, off, size))
        off += size
    return out, 32 + sizeofcmds


def code_signature(d):
    for cmd, off, _ in load_commands(d)[0]:
        if cmd == 0x1D:
            return (off, *struct.unpack_from('<II', d, off + 8))
    raise AssertionError('no LC_CODE_SIGNATURE')


def superblob(d):
    """(superblob offset, {slot type: (index position, absolute blob offset)})."""
    _, so, _ = code_signature(d)
    count = struct.unpack_from('>I', d, so + 8)[0]
    idx = {}
    for i in range(count):
        t, o = struct.unpack_from('>II', d, so + 12 + 8 * i)
        idx[t] = (i, so + o)
    return so, idx


def cd_offset(d):
    return superblob(d)[1][0][1]


def first_text_section(d):
    for cmd, off, _ in load_commands(d)[0]:
        if cmd == 0x19 and d[off + 8:off + 24].rstrip(b'\0') == b'__TEXT':
            return struct.unpack_from('<I', d, off + 72 + 48)[0]
    raise AssertionError('no __TEXT section')


def section(d, segname, sectname):
    """(header offset, file offset, size) of the first sectname in segname."""
    for cmd, off, _ in load_commands(d)[0]:
        if cmd == 0x19 and d[off + 8:off + 24].rstrip(b'\0') == segname.encode():
            for i in range(struct.unpack_from('<I', d, off + 64)[0]):
                hdr = off + 72 + 80 * i
                if d[hdr:hdr + 16].rstrip(b'\0') == sectname.encode():
                    size, offset = struct.unpack_from('<QI', d, hdr + 40)
                    return hdr, offset, size
    raise AssertionError('no %s,%s section' % (segname, sectname))


def rehash_pages(d):
    """Recomputes every code-page hash of the CodeDirectory, as a forger of an
    ad-hoc signature (no CMS signs the CodeDirectory) would."""
    d = bytearray(d)
    cd = cd_offset(d)
    hash_off, _, _, n_code, code_limit = struct.unpack_from('>5I', d, cd + 16)
    page = 1 << d[cd + 39]
    for i in range(n_code):
        h = hashlib.sha256(d[i * page:min((i + 1) * page, code_limit)]).digest()
        d[cd + hash_off + 32 * i:cd + hash_off + 32 * (i + 1)] = h
    return bytes(d)


def escaped(b):
    """How the tool prints untrusted bytes: printable ASCII except the
    backslash as is, everything else as \\xNN."""
    return ''.join(chr(c) if 0x20 <= c < 0x7F and c != 0x5C else '\\x%02x' % c for c in b)


def printable(out):
    return all(' ' <= c <= '~' for c in out.replace('\n', ''))


def patch(d, off, fmt, *values):
    d = bytearray(d)
    struct.pack_into(fmt, d, off, *values)
    return bytes(d)


def flip(d, off, mask=1):
    d = bytearray(d)
    d[off] ^= mask
    return bytes(d)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(dir=B.dir)

    def path(self, name, data=None):
        p = os.path.join(self.tmp, name)
        if data is not None:
            with open(p, 'wb') as f:
                f.write(data)
        return p

    def tool(self, *args, cwd=None):
        r = subprocess.run([B.tool, *(a if isinstance(a, bytes) else os.fsencode(a) for a in args)],
                           capture_output=True, env=RUN_ENV, timeout=120, cwd=cwd)
        res = types.SimpleNamespace(rc=r.returncode, out=r.stdout.decode(errors='replace'),
                                    err=r.stderr.decode(errors='replace'))
        for marker in ('AddressSanitizer', 'runtime error:', 'Sanitizer'):
            self.assertNotIn(marker, res.err)
        self.assertGreaterEqual(res.rc, 0, 'killed by signal: ' + res.err)
        return res

    def sign(self, src, mode='--adhoc', *extra, name='out.dylib'):
        out = self.path(name)
        r = self.tool(mode, *extra, src, out)
        self.assertEqual(r.rc, 0, r.err)
        return out

    def rejects(self, data, *messages, mode='--adhoc'):
        out = self.path('out.dylib')
        r = self.tool(mode, self.path('in.dylib', data), out)
        self.assertEqual(r.rc, 1, r.out + r.err)
        for m in messages:
            self.assertIn(m, r.err)
        self.assertFalse(os.path.exists(out), 'output written on failure')
        return r

    def verify(self, data):
        return self.tool('--verify', self.path('check.dylib', data))

    def verify_rejects(self, data, *messages):
        r = self.verify(data)
        self.assertEqual(r.rc, 1, r.out + r.err)
        for m in messages:
            self.assertIn(m, r.out + r.err)
        return r

    def assert_only_signing_changes(self, before, after):
        """Signing may only patch ncmds/sizeofcmds, stamp LC_CODE_SIGNATURE into
        the header pad and grow __LINKEDIT; every other input byte is kept."""
        cmds, cmds_end = load_commands(before)
        le = next(off for cmd, off, _ in cmds
                  if cmd == 0x19 and before[off + 8:off + 24].rstrip(b'\0') == b'__LINKEDIT')
        allowed = [(16, 24), (cmds_end, cmds_end + 16), (le + 32, le + 40), (le + 48, le + 56)]

        def masked(d):
            b = bytearray(d[:len(before)])
            for lo, hi in allowed:
                b[lo:hi] = bytes(hi - lo)
            return bytes(b)
        self.assertEqual(masked(before), masked(after), 'bytes changed outside the patched fields')
        self.assertEqual(before[cmds_end:cmds_end + 16], bytes(16))
        _, sig_off, sig_size = code_signature(after)
        self.assertEqual(after[len(before):sig_off], bytes(sig_off - len(before)))
        self.assertEqual(sig_off + sig_size, len(after))


# ---- Mach-O parser -------------------------------------------------------

class MachOParserTests(Base):
    def test_valid_synthetic_signs_and_verifies(self):
        data = valid()
        out = self.sign(self.path('in.dylib', data))
        self.assert_only_signing_changes(data, read(out))
        r = self.tool('--verify', out)
        self.assertEqual(r.rc, 0, r.out + r.err)
        self.assertIn('ad-hoc', r.out.splitlines()[-1])

    def test_exactly_16_bytes_of_header_pad(self):
        cmds_end = 32 + 152 + 72
        data = valid(sect_off=cmds_end + 16)
        out = read(self.sign(self.path('in.dylib', data)))
        self.assertEqual(out[cmds_end + 16:cmds_end + 24], CODE)
        self.assert_only_signing_changes(data, out)

    def test_linkedit_vmsize_grows_with_the_signature(self):
        data = macho([text(), linkedit(filesize=0x40, vmsize=0x40)], PAGE + 0x40, code=[0x3000])
        out = read(self.sign(self.path('in.dylib', data)))
        le = load_commands(out)[0][1][1]
        vmsize, fileoff, filesize = struct.unpack_from('<QQQ', out, le + 32)
        self.assertEqual((fileoff, fileoff + filesize), (PAGE, len(out)))
        self.assertEqual(vmsize, (filesize + 0x3fff) & ~0x3fff)

    def test_rejects_empty_file(self):
        self.rejects(b'', 'truncated')

    def test_rejects_bad_magic_and_fat(self):
        self.rejects(b'\xce\xfa\xed\xfe' + bytes(4096), 'not a thin 64-bit Mach-O')
        self.rejects(struct.pack('>II', 0xCAFEBABE, 1) + bytes(4096), 'not a thin 64-bit Mach-O')

    def test_rejects_other_cpu_and_file_type(self):
        self.rejects(macho([text(), linkedit()], PAGE + 0x40, cputype=0x01000007), 'not an arm64')
        self.rejects(macho([text(), linkedit()], PAGE + 0x40, filetype=1), 'unsupported Mach-O file type')

    def test_rejects_load_command_errors(self):
        d = valid()
        self.rejects(patch(d, 20, '<I', 10_000_000), 'extend past end of file')
        self.rejects(patch(d, 32 + 4, '<I', 0xFFFFFFF0), 'malformed load command')
        self.rejects(patch(d, 32 + 4, '<I', 156), 'malformed load command')  # not 8-aligned
        self.rejects(patch(d, 32 + 4, '<I', 0), 'malformed load command')
        self.rejects(patch(d, 16, '<I', 5000), 'implausible ncmds')
        self.rejects(patch(d, 16, '<I', 3), 'truncated load command')
        self.rejects(d[:12], 'truncated Mach-O header')
        self.rejects(macho([struct.pack('<II', 0x19, 64) + bytes(56), text(), linkedit()], PAGE + 0x40),
                     'short LC_SEGMENT_64')
        self.rejects(patch(d, 16, '<I', 1), 'sizeofcmds boundary')
        self.rejects(valid(extra=[struct.pack('<4I', 0x2, 16, 0, 0)]), 'malformed LC_SYMTAB')
        self.rejects(valid(extra=[struct.pack('<16I', 0x80000022, 64, *([0] * 14))]), 'malformed LC_DYLD_INFO')
        self.rejects(valid(extra=[struct.pack('<4I', 0xB, 16, 0, 0)]), 'malformed LC_DYSYMTAB')
        self.rejects(valid(extra=[struct.pack('<4I', 0x2C, 16, 0, 0)]), 'malformed LC_ENCRYPTION_INFO_64')
        self.rejects(valid(extra=[struct.pack('<4I', 0x31, 16, 0, 0)]), 'malformed LC_NOTE')

    def test_rejects_nsects_overflow(self):
        self.rejects(macho([seg('__TEXT', 0, PAGE, 0, PAGE, [sect('__text', '__TEXT', 0x3000)], nsects=0xFFFFFFFF),
                            linkedit()], PAGE + 0x40), 'does not match cmdsize')

    def test_rejects_segment_past_eof(self):
        self.rejects(macho([text(vmsize=0x100000, filesize=0x100000), linkedit()], PAGE + 0x40),
                     'extends past end of file')

    def test_segment_names_are_escaped(self):
        # 16 bytes without a NUL: newline, terminal escape, non-ASCII, backslash.
        name = b'__EVIL\n\x1b[2J\xff\\abc'
        r = self.rejects(macho([text(), seg(name, PAGE, PAGE, 0x100000, 0x10), linkedit(vmaddr=2 * PAGE)], PAGE + 0x40),
                         'segment __EVIL\\x0a\\x1b[2J\\xff\\x5cabc [0x100000, +0x10) extends past end of file')
        self.assertTrue(printable(r.err), r.err)

    def test_rejects_linkedit_past_eof(self):
        self.rejects(macho([text(), linkedit(fileoff=0x100000)], PAGE + 0x40), 'extends past end of file')

    def test_rejects_fileoff_filesize_wrap(self):
        self.rejects(macho([text(), seg('__LINKEDIT', PAGE, PAGE, 0x10, 2**64 - 8)], PAGE + 0x40),
                     'extends past end of file')

    def test_rejects_vm_wrap_and_filesize_over_vmsize(self):
        self.rejects(macho([text(), linkedit(vmaddr=2**64 - 0x1000)], PAGE + 0x40), 'wraps')
        self.rejects(macho([text(vmsize=0x2000), linkedit()], PAGE + 0x40), 'exceeds vmsize')

    def test_rejects_overlapping_segments(self):
        data = seg('__DATA', PAGE, PAGE, 0x2000, 0x1000)
        self.rejects(macho([text(), data, linkedit(vmaddr=2 * PAGE)], PAGE + 0x40), 'overlap in the file')
        data = seg('__DATA', 0x2000, PAGE, 0, 0)
        self.rejects(macho([text(), data, linkedit(vmaddr=2 * PAGE)], PAGE + 0x40), 'overlap in memory')

    def test_rejects_linkedit_not_last(self):
        data = seg('__DATA', 2 * PAGE, PAGE, 2 * PAGE, PAGE)
        self.rejects(macho([text(), linkedit(filesize=0x10), data], 3 * PAGE), 'not the last segment in the file')
        data = seg('__DATA', 2 * PAGE, PAGE, 0, 0)
        self.rejects(macho([text(), linkedit(), data], PAGE + 0x40), 'not the last segment in memory')

    def test_rejects_text_not_covering_the_header(self):
        # __TEXT at a non-zero file offset: the header lies in no segment.
        text_at = seg('__TEXT', 0, PAGE, 0x1000, 0x3000, [sect('__text', '__TEXT', 0x3000)])
        self.rejects(macho([text_at, linkedit()], PAGE + 0x40, code=[0x3000]), 'must start at file offset 0')
        # __TEXT without file content while another segment maps the header.
        data0 = seg('__DATA', PAGE, PAGE, 0, 0x1000)
        self.rejects(macho([seg('__TEXT', 0, PAGE, 0, 0), data0, linkedit(vmaddr=2 * PAGE)], PAGE + 0x40),
                     'must start at file offset 0')
        # A second segment at file offset 0 next to a valid __TEXT.
        self.rejects(macho([text(), data0, linkedit(vmaddr=2 * PAGE)], PAGE + 0x40), 'overlap in the file')
        # A segment starting inside the load commands.
        self.rejects(macho([text(), seg('__DATA', PAGE, PAGE, 0x40, 0x10), linkedit(vmaddr=2 * PAGE)], PAGE + 0x40),
                     'segment __DATA at file offset 0x40 overlaps the load commands')

    def test_text_must_hold_the_code_signature_command(self):
        cmds_end = 32 + 72 + 72
        short = lambda n: macho([seg('__TEXT', 0, PAGE, 0, n), linkedit()], PAGE + 0x40)
        self.rejects(short(cmds_end - 8), 'contain the load commands')
        self.rejects(short(cmds_end), 'no room for LC_CODE_SIGNATURE inside __TEXT')
        self.rejects(short(cmds_end + 8), 'no room for LC_CODE_SIGNATURE inside __TEXT')
        out = self.sign(self.path('in.dylib', short(cmds_end + 16)))
        self.assert_only_signing_changes(short(cmds_end + 16), read(out))
        self.assertEqual(self.tool('--verify', out).rc, 0)

    def test_rejects_trailing_data_after_linkedit(self):
        self.rejects(macho([text(), linkedit()], PAGE + 0x140), 'does not end at the end of the file')

    def test_rejects_segment_count_errors(self):
        self.rejects(macho([text(), linkedit(), linkedit()], PAGE + 0x40), 'more than one __LINKEDIT')
        self.rejects(macho([text(), text(), linkedit()], PAGE + 0x40), 'more than one __TEXT')
        self.rejects(macho([text()], PAGE), 'no __LINKEDIT')
        self.rejects(macho([linkedit(fileoff=0x1000, vmaddr=0)], 0x1040), 'no __TEXT')

    def test_rejects_section_in_header_pad(self):
        # __text starts 8 bytes after the load commands: no room, and the
        # file is long enough that only the section offset can tell.
        r = self.rejects(valid(sect_off=32 + 152 + 72 + 8), 'no room for LC_CODE_SIGNATURE', 'headerpad')
        self.assertIn('8 bytes of header pad', r.err)

    def test_rejects_section_inside_load_commands(self):
        self.rejects(valid(sect_off=184, code=False), 'overlaps the load commands')

    def test_rejects_section_outside_its_segment(self):
        self.rejects(valid(sect_off=PAGE - 4), "outside the segment's file range")

    def test_rejects_linkedit_data_in_header_pad(self):
        cmds_end = 32 + 152 + 72 + 16
        self.rejects(valid(extra=[linkedit_data(0x26, cmds_end + 4, 8)]), 'no room for LC_CODE_SIGNATURE')

    def test_rejects_dysymtab_table_in_header_pad(self):
        cmds_end = 32 + 152 + 72 + 80
        dysymtab = struct.pack('<20I', 0xB, 80, *([0] * 12), cmds_end + 8, 2, 0, 0, 0, 0)
        self.rejects(valid(extra=[dysymtab]), 'no room for LC_CODE_SIGNATURE')

    def test_rejects_unmodeled_data_in_header_pad(self):
        d = bytearray(valid())
        d[32 + 152 + 72 + 3] = 1  # e.g. data of a load command the parser does not model
        self.rejects(bytes(d), 'not zero-filled')

    def test_rejects_data_ranges_outside_the_file(self):
        self.rejects(valid(extra=[linkedit_data(0x26, PAGE + 0x38, 0x100)]), 'outside the file')
        self.rejects(valid(extra=[struct.pack('<6I', 0x26, 24, PAGE, 8, 0, 0)]), 'malformed linkedit_data_command')

    def test_rejects_data_inside_the_load_commands(self):
        self.rejects(valid(extra=[linkedit_data(0x26, 40, 8)]), 'references data at 0x28 inside the load commands')

    def test_rejects_already_signed(self):
        self.rejects(B.rsa, 'already has LC_CODE_SIGNATURE')

    def test_rejects_multiple_code_signatures(self):
        cs = linkedit_data(0x1D, PAGE + 0x20, 0x20)
        self.verify_rejects(macho([text(), linkedit(), cs, cs], PAGE + 0x40, code=[0x3000]),
                            'more than one LC_CODE_SIGNATURE')

    def test_rejects_code_signature_not_at_end(self):
        self.verify_rejects(macho([text(), linkedit(), linkedit_data(0x1D, PAGE, 0x10)], PAGE + 0x40),
                            'is not at the end of __LINKEDIT')

    def test_rejects_linkedit_data_in_the_signature(self):
        _, sig_off, _ = code_signature(B.rsa)
        off = next(o for c, o, _ in load_commands(B.rsa)[0] if c in (0x26, 0x29, 0x80000033, 0x80000034))
        dataoff = struct.unpack_from('<I', B.rsa, off + 8)[0]
        self.verify_rejects(patch(B.rsa, off + 12, '<I', sig_off - dataoff + 8), 'extends into the code signature')

    def test_real_dylib_keeps_all_input_bytes(self):
        before = read(B.ios_dylib)
        self.assert_only_signing_changes(before, B.adhoc)
        self.assert_only_signing_changes(before, B.rsa)


class ArgumentTests(Base):
    def test_non_utf8_arguments(self):
        r = self.tool(b'--adhoc', b'in\xffput.dylib', self.path('out.dylib'))
        self.assertEqual(r.rc, 1)
        self.assertIn('not valid UTF-8', r.err)
        r = self.tool(b'--adhoc', b'-i', b'\xff', B.ios_dylib, self.path('out.dylib'))
        self.assertEqual(r.rc, 1)
        self.assertIn('not valid UTF-8', r.err)
        r = self.tool(b'--verify', b'a\xff')
        self.assertEqual(r.rc, 1)
        self.assertIn('not valid UTF-8', r.err)

    def test_bad_identifiers(self):
        for ident in ('', 'a b', 'x' * 129, '.hidden', 'a/b', 'café'):
            r = self.tool('--adhoc', '-i', ident, B.ios_dylib, self.path('out.dylib'))
            self.assertEqual(r.rc, 1, ident)
            self.assertIn('invalid identifier', r.err)
        spaced = self.path('bad name.dylib', read(B.ios_dylib))
        r = self.tool('--adhoc', spaced, self.path('out.dylib'))
        self.assertEqual(r.rc, 1)
        self.assertIn('pass -i', r.err)
        self.assertFalse(os.path.exists(self.path('out.dylib')))

    def test_option_errors(self):
        for args in (['--bogus', B.ios_dylib, 'x'], ['-i'], ['--adhoc', '--team', 'ABCDE12345', B.ios_dylib, 'x'],
                     ['--adhoc', '-s', 'Apple', B.ios_dylib, 'x'], ['--adhoc', '--dry-run', B.ios_dylib, 'x'],
                     ['--adhoc', '--selftest', B.ios_dylib, 'x'], ['--verify', '--adhoc', B.rsa_path],
                     ['--team', 'bad team', B.ios_dylib, 'x'], ['--adhoc', B.ios_dylib]):
            r = self.tool(*args)
            self.assertEqual(r.rc, 1, args)
            self.assertIn('error:', r.err)

    def test_empty_paths(self):
        # Rejected before anything is read or written: no temporary file in the cwd.
        for args in (['--adhoc', B.ios_dylib, ''], ['--adhoc', '', 'out.dylib'], ['--verify', '']):
            r = self.tool(*args, cwd=self.tmp)
            self.assertEqual(r.rc, 1, args)
            self.assertIn('error: argument', r.err)
            self.assertIn('is an empty path', r.err)
        self.assertEqual(os.listdir(self.tmp), [])

    def test_output_is_atomic(self):
        existing = self.path('existing.dylib', b'keep me')
        self.rejects(valid(sect_off=264))  # headerpad failure
        r = self.tool('--adhoc', self.path('in.dylib'), existing)
        self.assertEqual(r.rc, 1)
        self.assertEqual(read(existing), b'keep me')
        r = self.tool('--adhoc', B.ios_dylib, os.path.join(self.tmp, 'missing-dir', 'out.dylib'))
        self.assertEqual(r.rc, 1)
        self.assertIn('temporary file', r.err)
        out = self.sign(B.ios_dylib, name='existing.dylib')
        self.assertEqual(read(out), B.adhoc)
        self.assertEqual(sorted(os.listdir(self.tmp)), ['existing.dylib', 'in.dylib'])
        self.assertEqual(os.stat(out).st_mode & 0o777, 0o755)


# ---- signing -------------------------------------------------------------

class AdhocTests(Base):
    def test_matches_codesign_byte_for_byte(self):
        for src in (B.ios_dylib, B.ios_bss, B.mac_dylib, B.mac_exe):
            ref = self.path('ref-' + os.path.basename(src), read(src))
            r = run(['codesign', '-s', '-', '-i', ADHOC_ID, ref])
            self.assertEqual(r.returncode, 0, r.stderr)
            out = self.sign(src, '--adhoc', '-i', ADHOC_ID, name='ours-' + os.path.basename(src))
            self.assertEqual(read(out), read(ref), 'differs from codesign -s - for ' + os.path.basename(src))

    def test_codesign_strict_and_verify_accept(self):
        for src in (B.ios_dylib, B.ios_bss, B.ios_exe, B.mac_dylib, B.mac_exe):
            out = self.sign(src, '--adhoc', name='adhoc-' + os.path.basename(src))
            r = run(['codesign', '-v', '--strict', out])
            self.assertEqual(r.returncode, 0, r.stderr)
            r = self.tool('--verify', out)
            self.assertEqual(r.rc, 0, r.out + r.err)
            self.assertIn('flags=0x2 ', r.out)
            self.assertIn('Signature=adhoc', r.out)
            self.assertEqual(r.out.splitlines()[-1], 'ad-hoc signature: hashes and coverage OK (no signer to verify)')

    def test_macos_dlopen(self):
        out = self.sign(B.mac_dylib, '--adhoc')
        r = run([B.host, out])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('guest_test returned 0x12345678', r.stdout)
        # Controls: the unsigned input and a tampered code page do not load.
        self.assertNotEqual(run([B.host, B.mac_dylib]).returncode, 0)
        tampered = self.path('tampered.dylib', flip(read(out), first_text_section(read(out))))
        self.assertNotEqual(run([B.host, tampered]).returncode, 0)

    def test_macos_executable_runs(self):
        out = self.sign(B.mac_exe, '--adhoc', name='exe')
        r = run([out])
        self.assertEqual((r.returncode, r.stdout), (7, '0x12345678\n'))
        self.assertIn('Executable Segment flags=0x1\n', self.tool('--verify', out).out)  # CS_EXECSEG_MAIN_BINARY
        self.assertEqual(run([B.mac_exe]).returncode, -9)  # control: unsigned arm64 code is killed

    def test_verify_accepts_codesign_and_linker_signatures(self):
        ref = self.path('codesign-adhoc.dylib', read(B.ios_dylib))
        self.assertEqual(run(['codesign', '-s', '-', ref]).returncode, 0)
        linker = os.path.join(self.tmp, 'linker-signed.dylib')
        build(['-arch', 'arm64', '-target', 'arm64-apple-macos14.0', '-dynamiclib',
               os.path.join(B.dir, 'fixture.c'), '-o', linker])
        for path in (ref, linker):
            r = self.tool('--verify', path)
            self.assertEqual(r.rc, 0, r.out + r.err)
            self.assertIn('ad-hoc signature', r.out)


class SelftestTests(Base):
    def test_rsa_codesign_and_verify(self):
        r = run(['codesign', '-v', '--strict', B.rsa_path])
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.tool('--verify', B.rsa_path)
        self.assertEqual(r.rc, 0, r.out + r.err)
        for line in ('Identifier=sgl-fixture', 'TeamIdentifier=SELFTEST00', 'slot -2 requirements hash: OK',
                     'CMS messageDigest: OK', 'CMS hash agility v2: OK', 'CMS hash agility v1 (cdhashes plist): OK',
                     'CMS signature (RSA PKCS#1 v1.5 SHA-256): OK'):
            self.assertIn(line + '\n', r.out)
        self.assertEqual(r.out.splitlines()[-1], 'hashes and coverage OK; signature and binding OK; trust not evaluated')
        cd = cd_offset(B.rsa)
        cd_len = struct.unpack_from('>I', B.rsa, cd + 4)[0]
        full = hashlib.sha256(B.rsa[cd:cd + cd_len]).hexdigest()
        self.assertIn('CDHash=%s\n' % full[:40], r.out)
        self.assertIn(base64.b64encode(bytes.fromhex(full[:40])), B.rsa)

    def test_other_layouts(self):
        # MH_EXECUTE with __PAGEZERO and a dylib with zerofill data: __LINKEDIT
        # vmaddr != fileoff in both.
        for src in (B.ios_exe, B.ios_bss):
            out = self.sign(src, '--selftest', name='st-' + os.path.basename(src))
            self.assertEqual(run(['codesign', '-v', '--strict', out]).returncode, 0)
            self.assertEqual(self.tool('--verify', out).rc, 0)

    def test_ecdsa_is_stable(self):
        sig_lengths = []
        for i in range(20):
            out = self.sign(B.ios_dylib, '--selftest-ec', name='ec%d.dylib' % i)
            r = self.tool('--verify', out)
            self.assertEqual(r.rc, 0, r.out + r.err)
            self.assertIn('CMS signature (ECDSA X9.62 SHA-256): OK', r.out)
            d = read(out)
            alg = d.rfind(b'\x30\x0a\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x02\x04')
            sig_lengths.append(d[alg + 13])
            if i == 0:
                r = run(['codesign', '-v', '--strict', out])
                self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(all(n <= 72 for n in sig_lengths), sig_lengths)
        # P(no signature shorter than the 72-byte reservation in 20 runs) ~ 1e-12
        self.assertTrue(any(n < 72 for n in sig_lengths), sig_lengths)

    def test_dry_run_placeholder_does_not_verify(self):
        out = self.sign(B.ios_dylib, '--selftest', '--dry-run')
        r = self.tool('--verify', out)
        self.assertEqual(r.rc, 1)
        self.assertIn('CMS messageDigest: OK', r.out)
        self.assertIn('zeroed placeholder', r.out)


# ---- --verify ------------------------------------------------------------

class VerifyTests(Base):
    def cd_field(self, d, off, fmt, value):
        return patch(d, cd_offset(d) + off, fmt, value)

    def test_rejects_unsigned(self):
        self.verify_rejects(read(B.ios_dylib), 'not signed')

    def test_tampered_page(self):
        r = self.verify_rejects(flip(B.rsa, PAGE))
        self.assertRegex(r.out, r'(?m)^page 1 \(\d+ bytes\): FAIL$')
        self.assertIn('page 0 (16384 bytes): OK', r.out)

    def test_forged_code_directory(self):
        # Rewriting the page hash to match tampered code changes the CD, which
        # the CMS messageDigest no longer matches.
        d = bytearray(flip(B.rsa, PAGE))
        cd, (_, sig_off, _) = cd_offset(d), code_signature(d)
        hash_off = struct.unpack_from('>I', d, cd + 16)[0]
        d[cd + hash_off + 32:cd + hash_off + 64] = hashlib.sha256(d[PAGE:min(2 * PAGE, sig_off)]).digest()
        r = self.verify_rejects(bytes(d), 'CMS messageDigest: FAIL', 'CMS hash agility v2: FAIL')
        self.assertRegex(r.out, r'(?m)^page 1 \(\d+ bytes\): OK$')
        self.assertIn('CMS signature (RSA PKCS#1 v1.5 SHA-256): OK', r.out)  # attributes untouched

    def test_tampered_cms_signature(self):
        d = B.rsa
        sig = d.rfind(b'\x04\x82\x01\x00')
        self.verify_rejects(flip(d, sig + 4 + 100), 'CMS signature (RSA PKCS#1 v1.5 SHA-256): FAIL')

    def test_tampered_requirements(self):
        _, idx = superblob(B.rsa)
        self.verify_rejects(flip(B.rsa, idx[2][1] + 30), 'slot -2 requirements hash: FAIL')

    def test_unbound_requirements(self):
        self.verify_rejects(self.cd_field(B.rsa, 24, '>I', 0), 'blob present but not bound')

    def test_bound_external_slot(self):
        d = bytearray(B.adhoc)
        cd = cd_offset(d)
        hash_off = struct.unpack_from('>I', d, cd + 16)[0]
        d[cd + hash_off - 32] = 1  # slot -1 (Info.plist) bound without an Info.plist
        self.verify_rejects(bytes(d), 'slot -1 Info.plist: FAIL', 'there is no __TEXT,__info_plist section')

    def test_embedded_info_plist(self):
        # codesign binds an Info.plist linked into __TEXT,__info_plist through
        # special slot -1: the SHA-256 of the section's raw bytes.
        src = self.path('plist.dylib')
        build(['-arch', 'arm64', '-target', 'arm64-apple-macos14.0', '-dynamiclib', '-Wl,-no_adhoc_codesign',
               '-Wl,-sectcreate,__TEXT,__info_plist,' + self.path('Info.plist', INFO_PLIST),
               os.path.join(B.dir, 'fixture.c'), '-o', src])
        ref = self.path('codesign.dylib', read(src))
        r = run(['codesign', '-s', '-', ref])
        self.assertEqual(r.returncode, 0, r.stderr)
        d = read(ref)
        hdr, off, size = section(d, '__TEXT', '__info_plist')
        self.assertEqual(d[off:off + size], INFO_PLIST)
        cd = cd_offset(d)
        hash_off = struct.unpack_from('>I', d, cd + 16)[0]
        self.assertEqual(d[cd + hash_off - 32:cd + hash_off], hashlib.sha256(INFO_PLIST).digest())
        r = self.verify(d)
        self.assertEqual(r.rc, 0, r.out + r.err)
        self.assertIn('Identifier=sgl.plist.test\n', r.out)  # codesign takes it from CFBundleIdentifier
        self.assertIn('slot -1 Info.plist hash: OK\n', r.out)
        # Tampered plist bytes fail the page and the slot; with the page hashes
        # recomputed only the slot catches it.
        tampered = flip(d, off + INFO_PLIST.index(b'sgl.plist.test'))
        r = self.verify_rejects(tampered, 'slot -1 Info.plist hash: FAIL')
        self.assertRegex(r.out, r'(?m)^page 0 \(\d+ bytes\): FAIL$')
        self.verify_rejects(rehash_pages(tampered), 'slot -1 Info.plist hash: FAIL', 'verification FAILED (1 problems)')
        # The section is bounds-checked: a zerofill-typed __info_plist (whose
        # offset the parser does not range-check) pointing past the file.
        for offset, flags in ((len(d), 1), (len(d) - size + 1, 1), (0xFFFFFFFF, 0xC)):
            outside = patch(patch(d, hdr + 48, '<I', offset), hdr + 64, '<I', flags)
            self.verify_rejects(rehash_pages(outside), '__TEXT,__info_plist lies outside the file',
                                'verification FAILED (1 problems)')
        # Our signer leaves the Info.plist unbound, which codesign accepts.
        out = self.sign(src, '--adhoc', '-i', 'sgl.plist.test')
        self.assertEqual(run(['codesign', '-v', '--strict', out]).returncode, 0)
        r = self.tool('--verify', out)
        self.assertEqual(r.rc, 0, r.out + r.err)
        self.assertIn('slot -1 Info.plist: not bound\n', r.out)

    def test_certificate_names_are_escaped(self):
        # Certificate names are attacker-controlled: control characters, the
        # backslash and non-ASCII bytes print as \xNN, so a name can neither
        # forge output lines nor emit terminal escapes. The CMS signature does
        # not cover the certificates, so the edited signature still verifies.
        cms = superblob(B.rsa)[1][0x10000][1]
        certs = B.rsa.index(b'\xa0\x82', cms)
        end = certs + 4 + struct.unpack_from('>H', B.rsa, certs + 2)[0]
        cn = b'sign-local self-test'
        subject_cn = B.rsa.index(cn, B.rsa.index(cn, certs, end) + 1, end)  # after the issuer's
        evil = b'\nForged=OK\x1b[2K\\\x07\xc3\xa9!!'
        self.assertEqual(len(evil), len(cn))
        r = self.verify(B.rsa[:subject_cn] + evil + B.rsa[subject_cn + len(cn):])
        self.assertEqual(r.rc, 0, r.out + r.err)
        self.assertIn('Authority=Apple Development: \\x0aForged=OK\\x1b[2K\\x5c\\x07\\xc3\\xa9!!\n', r.out)
        self.assertNotRegex(r.out, '(?m)^Forged')
        self.assertTrue(printable(r.out), r.out)
        # The subject OU, printed when it does not back the CodeDirectory team.
        ou_oid = b'\x06\x03\x55\x04\x0b'
        ou = B.rsa.index(ou_oid, B.rsa.index(ou_oid, certs, end) + 1, end)
        self.assertEqual(B.rsa[ou + 5:ou + 17], b'\x0c\x0aSELFTEST00')
        r = self.verify_rejects(B.rsa[:ou + 7] + b'EVIL\n\x1b[1m!' + B.rsa[ou + 17:],
                                'TeamIdentifier binding: FAIL (CodeDirectory SELFTEST00, signer certificate OU '
                                'EVIL\\x0a\\x1b[1m!)\n')
        self.assertTrue(printable(r.out), r.out)

    def test_code_directory_must_cover_the_file(self):
        _, sig_off, _ = code_signature(B.rsa)
        self.verify_rejects(self.cd_field(flip(B.rsa, PAGE), 28, '>I', 1), 'does not cover codeLimit')
        self.verify_rejects(self.cd_field(B.rsa, 28, '>I', 0), 'does not cover codeLimit')
        self.verify_rejects(self.cd_field(B.rsa, 32, '>I', sig_off - 0x80), 'does not end at the signature')

    def test_bad_page_sizes(self):
        for bits in (0, 11, 13, 15, 16, 32, 40, 63, 64, 70, 200, 255):
            self.verify_rejects(self.cd_field(B.rsa, 39, 'B', bits), 'unsupported CodeDirectory page size')

    def test_bad_code_directory_fields(self):
        cd_len = struct.unpack_from('>I', B.rsa, cd_offset(B.rsa) + 4)[0]
        self.verify_rejects(self.cd_field(B.rsa, 20, '>I', 0), 'identifier is missing or invalid')
        self.verify_rejects(self.cd_field(B.rsa, 20, '>I', cd_len), 'identifier is missing or invalid')
        self.verify_rejects(self.cd_field(B.rsa, 0x58, 'B', 0xff), 'identifier is missing or invalid')
        self.verify_rejects(self.cd_field(B.rsa, 0x30, '>I', cd_len - 1), 'team identifier is invalid')
        self.verify_rejects(self.cd_field(B.rsa, 37, 'B', 1), 'unsupported hash type')
        self.verify_rejects(self.cd_field(B.rsa, 8, '>I', 0x20001), 'unsupported CodeDirectory version')
        self.verify_rejects(self.cd_field(B.rsa, 0x2c, '>I', 0x60), 'scatter')
        self.verify_rejects(self.cd_field(B.rsa, 0x38, '>Q', 1), '64-bit codeLimit')
        self.verify_rejects(self.cd_field(B.rsa, 4, '>I', cd_len - 1), 'hash array overruns')
        self.verify_rejects(self.cd_field(B.rsa, 24, '>I', 8), 'special slots')
        # v0x20500 adds encryption fields at 0x58: 0x5c then reads identifier bytes.
        self.verify_rejects(self.cd_field(B.rsa, 8, '>I', 0x20500), 'pre-encryption hashes are unsupported')

    def test_adhoc_flag_with_cms(self):
        self.verify_rejects(self.cd_field(B.rsa, 12, '>I', 2), 'CMS: FAIL (ad-hoc CodeDirectory with a CMS signature)')

    def test_superblob_index(self):
        so, idx = superblob(B.rsa)
        self.verify_rejects(flip(B.rsa, so + 3), 'bad superblob magic 0xfade0cc1')
        self.verify_rejects(patch(B.rsa, so + 8, '>5I', 2, 2, idx[2][1] - so, 0x10000, idx[0x10000][1] - so),
                            'no CodeDirectory in superblob')
        self.verify_rejects(patch(B.rsa, so + 8, '>I', 0x7FFFFFFF), 'bad superblob index')
        self.verify_rejects(patch(B.rsa, so + 8, '>I', 0), 'bad superblob index')
        self.verify_rejects(patch(B.rsa, so + 12 + 8 * idx[2][0], '>I', 0), 'duplicate superblob slot')
        self.verify_rejects(patch(B.rsa, so + 12 + 8 * idx[2][0], '>I', 0x1000), 'alternate CodeDirectories')
        self.verify_rejects(patch(B.rsa, so + 12 + 8 * idx[2][0], '>I', 9), 'unsupported superblob slot')
        self.verify_rejects(patch(B.rsa, so + 16 + 8 * idx[2][0], '>I', idx[0][1] - so), 'overlap')
        self.verify_rejects(patch(B.rsa, so + 16 + 8 * idx[2][0], '>I', 12), 'outside the superblob')
        self.verify_rejects(patch(B.rsa, so + 16 + 8 * idx[2][0], '>I', 0xFFFFFFFE), 'outside the superblob')
        self.verify_rejects(patch(B.rsa, idx[2][1], '>I', 0xFADE0C00), 'has magic')
        self.verify_rejects(patch(B.rsa, idx[0][1], '>I', 0xFADE0C01), 'has magic')
        self.verify_rejects(patch(B.rsa, idx[0x10000][1], '>I', 0xFADE0B02), 'has magic')

    def test_blob_beyond_superblob(self):
        so, idx = superblob(B.rsa)
        cms = idx[0x10000][1]
        cms_len = struct.unpack_from('>I', B.rsa, cms + 4)[0]
        self.verify_rejects(patch(B.rsa, cms + 4, '>I', cms_len + 16), 'outside the superblob')
        _, _, sig_size = code_signature(B.rsa)
        self.verify_rejects(patch(B.rsa, so + 4, '>I', sig_size + 1), 'superblob length')
        self.verify_rejects(patch(B.adhoc, len(B.adhoc) - 1, 'B', 1), 'non-zero bytes after the superblob')

    def test_cms_missing_or_garbled(self):
        so, idx = superblob(B.rsa)
        self.verify_rejects(patch(B.rsa, so + 8, '>I', 2), 'no CMS signature')  # CMS index entry dropped
        cms = idx[0x10000][1]
        d = bytearray(B.rsa)
        for i in range(cms + 200, cms + 264):
            d[i] ^= 0x5A
        r = self.verify_rejects(bytes(d))
        self.assertIn('CMS', r.out + r.err)

    def test_cms_der_length_attacks(self):
        so, idx = superblob(B.rsa)
        cms = idx[0x10000][1] + 8
        self.assertEqual(B.rsa[cms:cms + 2], b'\x30\x80')
        self.verify_rejects(patch(B.rsa, cms + 1, 'B', 0x85), 'CMS: malformed ContentInfo')
        certs = B.rsa.index(b'\xa0\x82', cms)  # [0] certificates
        self.verify_rejects(patch(B.rsa, certs + 2, '>H', 0xFFFF), 'CMS:')
        attrs = B.rsa.index(b'\x06\x09\x60\x86\x48\x01\x65\x03\x04\x02\x01\x05\x00\xa0', certs) + 13
        self.verify_rejects(patch(B.rsa, attrs + 1, 'B', 0x80), 'CMS: no signed attributes')
        self.verify_rejects(patch(B.rsa, attrs + 2, '>H', 0xFFFF), 'CMS:')
        md = B.rsa.index(b'\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x09\x04\x31\x22\x04\x20', attrs)
        self.verify_rejects(patch(B.rsa, md + 14, 'B', 0x84), 'CMS:')

    def test_cms_algorithm_identifiers(self):
        cms = superblob(B.rsa)[1][0x10000][1]
        dalgs = B.rsa.index(b'\x31\x0f' + SHA256_ALG, cms)   # SignedData digestAlgorithms
        si_dalg = B.rsa.index(SHA256_ALG + b'\xa0', cms)     # SignerInfo digestAlgorithm
        salg = B.rsa.index(RSA_SHA256_ALG + b'\x04', cms)    # SignerInfo signatureAlgorithm
        # Parameters other than absent or NULL (05 00 -> 04 00).
        self.verify_rejects(flip(B.rsa, dalgs + 15), 'digest algorithms (need v1, SHA-256)')
        self.verify_rejects(flip(B.rsa, si_dalg + 13), 'unsupported digest algorithm')
        self.verify_rejects(flip(B.rsa, salg + 13), 'malformed signature algorithm')
        self.verify_rejects(patch(B.rsa, salg + 12, 'B', 0x0C), 'unsupported signature algorithm')  # sha384WithRSA
        # SHA-256 without parameters (RFC 5754; Apple's own signatures) is
        # accepted: drop the NULL from digestAlgorithms and shrink the CMS.
        so = superblob(B.rsa)[0]
        d = B.rsa[:dalgs] + b'\x31\x0d\x30\x0b' + SHA256_ALG[2:13] + B.rsa[dalgs + 17:] + bytes(2)
        for off in (so + 4, cms + 4):  # superblob and CMS wrapper lengths
            d = patch(d, off, '>I', struct.unpack_from('>I', d, off)[0] - 2)
        r = self.verify(d)
        self.assertEqual(r.rc, 0, r.out + r.err)
        self.assertIn('CMS signature (RSA PKCS#1 v1.5 SHA-256): OK', r.out)

    def test_signer_serial_and_team(self):
        # The SignerInfo serial (right before its digestAlgorithm) names a
        # certificate that is not embedded.
        cms = superblob(B.rsa)[1][0x10000][1]
        self.verify_rejects(flip(B.rsa, B.rsa.index(SHA256_ALG + b'\xa0', cms) - 1), 'signer certificate is not embedded')
        # The signer's subject OU must back the CodeDirectory team. The leaf is
        # self-signed: its issuer OU comes first, then the subject OU.
        certs = B.rsa.index(b'\xa0\x82', cms)
        end = certs + 4 + struct.unpack_from('>H', B.rsa, certs + 2)[0]
        ou_oid = b'\x06\x03\x55\x04\x0b'
        ou = B.rsa.index(ou_oid, B.rsa.index(ou_oid, certs, end) + 1, end)
        self.assertEqual(B.rsa[ou + 5:ou + 17], b'\x0c\x0aSELFTEST00')
        for d, shown in ((patch(B.rsa, ou + 4, 'B', 0x0C), 'OU missing or unreadable'),  # no OU attribute
                         (flip(B.rsa, ou + 7, 0x80), 'OU missing or unreadable'),        # OU not UTF-8
                         (flip(B.rsa, ou + 16), 'OU SELFTEST01')):                        # another team
            r = self.verify_rejects(d, 'TeamIdentifier binding: FAIL (CodeDirectory SELFTEST00, signer certificate')
            self.assertIn(shown, r.out)
            self.assertIn('CMS signature (RSA PKCS#1 v1.5 SHA-256): OK', r.out)

    def test_accepts_apple_platform_signature(self):
        # Apple's CMS: three certificates, SHA-256 without NULL parameters.
        out = self.path('ls-arm64e')
        if run(['lipo', '/bin/ls', '-thin', 'arm64e', '-output', out]).returncode != 0:
            self.skipTest('/bin/ls has no arm64e slice on this host')
        r = self.tool('--verify', out)
        self.assertEqual(r.rc, 0, r.out + r.err)
        self.assertIn('CMS signature (RSA PKCS#1 v1.5 SHA-256): OK', r.out)

    def test_code_signature_command_size(self):
        cs, _, _ = code_signature(B.rsa)
        self.verify_rejects(patch(B.rsa, cs + 4, '<I', 8), 'LC_CODE_SIGNATURE', 'expected 16')
        self.verify_rejects(patch(B.rsa, cs + 8, '<I', len(B.rsa) + 0x100), 'outside the file')
        self.verify_rejects(patch(B.rsa, cs + 12, '<I', 0), 'empty LC_CODE_SIGNATURE')


class InternalTests(unittest.TestCase):
    """DER/BER parsing, certificate and identity selection logic, signature
    size bounds, identifier/time validation, CMS signer-certificate binding
    and the atomic writer's path check, called directly."""

    def group(self, *args, rc=0, cwd=None):
        r = subprocess.run([B.harness, *args], capture_output=True, text=True, env=RUN_ENV, timeout=300, cwd=cwd)
        self.assertNotIn('Sanitizer', r.stderr)
        self.assertNotIn('runtime error', r.stderr)
        self.assertEqual(r.returncode, rc, r.stdout + r.stderr)
        return r

    def test_cms_signer_certificate(self):
        self.group('cms', 'ok')
        r = self.group('cms', 'noou')
        self.assertIn('TeamIdentifier binding: FAIL (CodeDirectory SELFTEST00, signer certificate OU missing', r.stdout)
        r = self.group('cms', 'dupcert', rc=1)
        self.assertIn('more than one certificate matches the signer', r.stderr)

    def test_cms_certificate_names_are_escaped_and_bounded(self):
        r = self.group('cms', 'evil')
        cn = b'Apple Development: \\x0a\n\x1b[31m\xc3\xa9'.ljust(321, b'A')
        authority = 'Authority=' + escaped(cn[:128]) + '...'
        self.assertTrue(authority.startswith('Authority=Apple Development: \\x5cx0a\\x0a\\x1b[31m\\xc3\\xa9AAA'))
        self.assertEqual(r.stdout.count(authority + '\n'), 2, r.stdout)  # with and without a team
        self.assertIn('TeamIdentifier binding: FAIL (CodeDirectory SELFTEST00, signer certificate OU '
                      'SELFTEST00\\x0a\\x1b[0m)\n', r.stdout)
        self.assertTrue(printable(r.stdout), r.stdout)

    def test_atomic_write_rejects_empty_path(self):
        tmp = tempfile.mkdtemp(dir=B.dir)
        r = self.group('atomic', rc=1, cwd=tmp)
        self.assertIn('empty output path', r.stderr)
        self.assertEqual(os.listdir(tmp), [])

    def test_der(self):
        self.group('der')

    def test_ber(self):
        self.group('ber')

    def test_der_int(self):
        self.group('derint')

    def test_ecdsa_signature_bound(self):
        self.group('ecbound')

    def test_identity_selection(self):
        self.group('identity')

    def test_chain_selection(self):
        self.group('chain')

    def test_identifier_validation(self):
        self.group('ident')

    def test_time_parsing(self):
        self.group('time')


# ---- real identity (opt-in) ------------------------------------------------

CS_VARIABLE = ('Executable=', 'CDHash', 'CandidateCDHash', 'CMSDigest', 'Signed Time', 'Signature size', 'Timestamp')


def codesign_fields(path, drop=()):
    r = run(['codesign', '-dv', '--verbose=4', path])
    return [l for l in r.stderr.splitlines() if not l.startswith(CS_VARIABLE + tuple(drop))]


def cms_variable_ranges(cms):
    """Signing time, CD digests, cdhashes plist and signature value, located
    structurally; each must be present exactly once."""
    ranges = []
    for prefix, size in ((b'\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x09\x05\x31\x0f\x17\x0d', 13),
                         (b'\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x09\x04\x31\x22\x04\x20', 32),
                         (b'\x06\x09\x60\x86\x48\x01\x65\x03\x04\x02\x01\x04\x20', 32)):
        assert cms.count(prefix) == 1, prefix.hex()
        i = cms.index(prefix) + len(prefix)
        ranges.append((i, i + size))
    lo = cms.index(b'<data>') + 6
    ranges.append((lo, cms.index(b'</data>', lo)))
    alg = b'\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0b\x05\x00\x04\x82'
    assert cms.count(alg) == 1, 'expected an RSA signature'
    i = cms.index(alg) + len(alg)
    ranges.append((i + 2, i + 2 + int.from_bytes(cms[i:i + 2], 'big')))
    return ranges


@unittest.skipUnless(KEYCHAIN_TESTS, 'keychain tests are opt-in: set TOLKARA_SIGN_KEYCHAIN_TESTS=1 (uses SIGN_IDENTITY '
                                     'and DEVELOPMENT_TEAM; may show a keychain approval dialog)')
class KeychainTests(Base):
    @classmethod
    def setUpClass(cls):
        cls.identity = ['-s', os.environ.get('SIGN_IDENTITY') or 'Apple Development']
        if os.environ.get('DEVELOPMENT_TEAM'):
            cls.identity += ['--team', os.environ['DEVELOPMENT_TEAM']]

    def reference(self):
        """Dry-run with the selected identity, and codesign(1) with the same
        certificate (by SHA-1) on an identically named copy."""
        os.makedirs(self.path('ours'))
        os.makedirs(self.path('ref'))
        dry = self.path('ours/sgl-fixture.dylib')
        r = self.tool('--dry-run', *self.identity, B.ios_dylib, dry)
        self.assertEqual(r.rc, 0, r.err)
        sha1 = re.search(r'^identity: ([0-9A-F]{40}) ', r.err, re.M).group(1)
        ref = self.path('ref/sgl-fixture.dylib', read(B.ios_dylib))
        r = run(['codesign', '-f', '-s', sha1, '-i', 'sgl-fixture', ref])
        self.assertEqual(r.returncode, 0, r.stderr)
        return sha1, dry, ref

    def test_dry_run_matches_codesign_reference(self):
        _, dry, ref = self.reference()
        r = self.tool('--verify', dry)
        self.assertEqual(r.rc, 1)
        self.assertIn('CMS messageDigest: OK', r.out)
        self.assertIn('zeroed placeholder', r.out)
        self.assertEqual(codesign_fields(ref, ['Authority']), codesign_fields(dry, ['Authority']))

        def blobs(d):
            _, idx = superblob(d)
            return {t: d[o:o + struct.unpack_from('>I', d, o + 4)[0]] for t, (_, o) in idx.items()}
        rb, ob = blobs(read(ref)), blobs(read(dry))
        self.assertEqual(sorted(rb), sorted(ob))
        hash_off = struct.unpack_from('>I', rb[0], 16)[0]
        # Page hashes differ: the reserved LC_CODE_SIGNATURE datasize differs.
        self.assertEqual(rb[0][:hash_off], ob[0][:hash_off], 'CodeDirectory header, strings or special slots differ')
        self.assertEqual(rb[2], ob[2], 'requirements differ')
        rc, oc = rb[0x10000][8:], ob[0x10000][8:]
        self.assertEqual(len(rc), len(oc))

        def masked(cms):
            b = bytearray(cms)
            for lo, hi in cms_variable_ranges(cms):
                b[lo:hi] = bytes(hi - lo)
            return bytes(b)
        self.assertEqual(masked(rc), masked(oc), 'CMS structure differs from codesign')
        self.assertIn(base64.b64encode(hashlib.sha256(ob[0]).digest()[:20]), oc)

    def test_real_signature(self):
        sha1, _, ref = self.reference()
        out = self.path('ours/signed.dylib')
        r = self.tool('-i', 'sgl-fixture', '-s', sha1, B.ios_dylib, out)
        if r.rc == 3:
            self.fail('the keychain denied access to the signing key; rerun and choose "Always Allow"')
        self.assertEqual(r.rc, 0, r.err)
        r = run(['codesign', '-v', '--strict', out])
        self.assertEqual(r.returncode, 0, r.stderr)
        for path in (out, ref):
            r = self.tool('--verify', path)
            self.assertEqual(r.rc, 0, r.out + r.err)
            self.assertEqual(r.out.splitlines()[-1], 'hashes and coverage OK; signature and binding OK; trust not evaluated')
            cs = run(['codesign', '-dv', '--verbose=4', path]).stderr
            for key in ('TeamIdentifier', 'CDHash'):
                want = re.search(r'^%s=(\S+)$' % key, cs, re.M).group(1)
                self.assertIn('%s=%s\n' % (key, want), r.out)
        self.assertEqual(codesign_fields(ref), codesign_fields(out))


if __name__ == '__main__':
    unittest.main()
