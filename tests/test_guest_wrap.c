#include "GuestWrap.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static long add_seven(long a, long b, long c, long d, long e, long f, long g) {
    return a + b + c + d + e + f + g;
}
static void *identity(void *p) { return p; }
static double through_eight(double a, double b, double c, double d, double e, double f, double g, double h) {
    return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8;
}
struct big { long v[8]; };
static struct big fill(long first) {
    struct big made;
    for (int i = 0; i < 8; i++) made.v[i] = first + i;
    return made;
}
static long (*countdown_wrapped)(long);
static long countdown(long n) { return n ? countdown_wrapped(n - 1) + 1 : 0; }

static unsigned occurrences(const char *text, const char *needle) {
    unsigned count = 0;
    for (const char *at = text; (at = strstr(at, needle)); at += strlen(needle)) count++;
    return count;
}

int main(void) {
    FILE *log = tmpfile();
    assert(log);
    gw_log(log);

    long (*add)(long, long, long, long, long, long, long) = (void *)gw_wrap("add_seven", (void *)add_seven);
    assert(add && (void *)add != (void *)add_seven);
    assert(gw_wrap("add_seven", (void *)add_seven) == (void *)add);
    assert(gw_used() == 1);
    assert(add(1, 2, 3, 4, 5, 6, 7) == 28);

    void *(*same)(void *) = (void *)gw_wrap("identity", (void *)identity);
    int marker;
    assert(same(&marker) == &marker);

    double (*mixed)(double, double, double, double, double, double, double, double) =
        (void *)gw_wrap("through_eight", (void *)through_eight);
    assert(mixed(1, 2, 3, 4, 5, 6, 7, 8) == through_eight(1, 2, 3, 4, 5, 6, 7, 8));

    // A result over sixteen bytes goes through x8, which must survive the call.
    struct big (*made)(long) = (void *)gw_wrap("fill", (void *)fill);
    struct big got = made(10);
    for (int i = 0; i < 8; i++) assert(got.v[i] == 10 + i);

    // A wrapped function may call back into a wrapped function.
    countdown_wrapped = (void *)gw_wrap("countdown", (void *)countdown);
    assert(countdown_wrapped(30) == 30);

    assert(!gw_wrap("nothing", NULL));
    assert(gw_wrap(NULL, (void *)identity) == (void *)identity);
    assert(gw_used() == 5);

    fflush(log);
    rewind(log);
    char text[16384];
    size_t length = fread(text, 1, sizeof text - 1, log);
    text[length] = 0;
    fclose(log);
    assert(occurrences(text, "[wrap] add_seven #1 [t1] enter") == 1);
    assert(occurrences(text, "[wrap] add_seven #1 [t1] leave = 0x1c") == 1);
    assert(occurrences(text, "[wrap] identity #1 [t1] enter") == 1);
    assert(occurrences(text, "countdown #") == 62);
    assert(strstr(text, "caller=0x"));

    gw_reset();
    assert(gw_used() == 0);
    return 0;
}
