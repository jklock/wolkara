// Our own disposable debugserver fixture. Never loads or executes guest code.
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>
static const unsigned char challenge[32]={1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,
    17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32};
int main(void) {
    void *arena=mmap(NULL,16384,PROT_READ|PROT_EXEC,MAP_PRIVATE|MAP_ANON,-1,0);
    if(arena==MAP_FAILED)return 1;
    printf("{\"pid\":%u,\"uid\":%u,\"address\":%llu,\"challengeAddress\":%llu}\n",
        (unsigned)getpid(),(unsigned)geteuid(),(unsigned long long)(uintptr_t)arena,
        (unsigned long long)(uintptr_t)challenge);
    fflush(stdout);
    (void)getchar();
    int result=0;
    for(unsigned i=0;i<16384;i++)if(((const unsigned char *)arena)[i])result=2;
    munmap(arena,16384);return result;
}
