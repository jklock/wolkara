#include "GuestTLS.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
static GuestTLS tls, library;
static uint64_t descriptors[2][3]={{0,0,0},{0,0,64}};
static uint64_t library_descriptors[1][3]={{0,0,16}};
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
    // A second image has storage of its own.
    unsigned char library_template[32]={0}; library_template[16]=5;
    assert(gt_create(&library,library_template,sizeof library_template,16,
                     (uintptr_t)library_descriptors,sizeof library_descriptors));
    assert(!gt_address(&library,descriptors[0]) && !gt_address(&tls,library_descriptors[0]));
    unsigned char *library_value=gt_address(&library,library_descriptors[0]);
    assert(library_value && library_value[0]==5 && library_value!=main_value);
    gt_destroy(&library);
    gt_destroy(&tls);
    assert(!gt_address(&tls,descriptors[0]));
    // An image declaring descriptors and carrying no template.
    static uint64_t served_descriptors[1][3]={{0,0,16}}, bare_descriptors[2][3]={{0,0,0},{0,0,8}};
    static GTImage images[2], none;
    assert(gt_register(&images[0],"served",library_template,sizeof library_template,16,
                       (uintptr_t)served_descriptors,sizeof served_descriptors));
    assert(gt_register(&images[1],"bare",NULL,0,0,(uintptr_t)bare_descriptors,sizeof bare_descriptors));
    const char *owner=NULL;
    unsigned char *served=gt_find(images,2,served_descriptors[0],&owner);
    assert(served && served[0]==5 && owner && !strcmp(owner,"served"));
    // Refused, and named, rather than stopping at registration.
    assert(!gt_find(images,2,bare_descriptors[1],&owner) && owner && !strcmp(owner,"bare"));
    uint64_t stray[3]={0,0,0};
    assert(!gt_find(images,2,stray,&owner) && !owner);
    // No descriptors: nothing to register.
    assert(!gt_register(&none,"none",NULL,0,0,(uintptr_t)bare_descriptors,0));
    gt_destroy(&images[0].tls);
    puts("PASS: native TLS template per image, alignment, thread isolation, bounds and arm64 register preservation,"
         " descriptors without a template refused by name");
}
