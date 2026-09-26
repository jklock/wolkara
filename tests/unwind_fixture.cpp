struct Cleanup {
    int *count;
    ~Cleanup() { ++*count; }
};
extern "C" __attribute__((noinline)) void fixture_throw(int value, int *cleaned) {
    Cleanup cleanup{cleaned};
    throw value;
}
extern "C" __attribute__((noinline)) int fixture_catch(int value, int *cleaned) {
    Cleanup cleanup{cleaned};
    try { fixture_throw(value, cleaned); }
    catch (int caught) { return caught + 1; }
    return -1;
}
