#include "GuestTLS.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
static GuestTLS tls;
static uint64_t descriptors[2][3]={{0,0,0},{0,0,64}};
static void *worker(void *arg) {
    (void)arg;
    unsigned char *a=gt_address(&tls,descriptors[0]);
    unsigned char *b=gt_address(&tls,descriptors[1]);
    assert(a && b==a+64 && !((uintptr_t)a&63));
    assert(a[0]==7 && b[0]==0); a[0]=99; b[0]=42;
    assert(gt_address(&tls,descriptors[0])==a);
    return NULL;
}
void *guest_tlv_address(const uint64_t descriptor[3]) { return gt_address(&tls,descriptor); }
extern int test_tlv_registers(const uint64_t descriptor[3]);
int main(void) {
    unsigned char template[128]={7};
    assert(gt_create(&tls,template,sizeof template,64,(uintptr_t)descriptors,sizeof descriptors));
    unsigned char *main_value=gt_address(&tls,descriptors[0]); assert(main_value[0]==7); main_value[0]=11;
    pthread_t threads[8];
    for(size_t i=0;i<8;i++) assert(!pthread_create(&threads[i],NULL,worker,NULL));
    for(size_t i=0;i<8;i++) assert(!pthread_join(threads[i],NULL));
    assert(main_value[0]==11 && main_value[64]==0);
    assert(!gt_address(&tls,(const uint64_t *)((uintptr_t)descriptors+8)));
    descriptors[1][2]=128; assert(!gt_address(&tls,descriptors[1]));
    assert(test_tlv_registers(descriptors[0])==1);
    gt_destroy(&tls);
    assert(!gt_address(&tls,descriptors[0]));
    puts("PASS: native TLS template, alignment, thread isolation, bounds and arm64 register preservation");
}
