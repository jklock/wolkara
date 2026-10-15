#include "CPUProbe.h"
#include "GuestCPU.h"
#include <stdlib.h>
#include <time.h>
#include <inttypes.h>

extern uint64_t gc_probe_program(uint64_t iterations,uint64_t seed);
extern const unsigned char gc_probe_program_end[];
extern uint64_t gc_probe_memory_program(uint64_t iterations,uint64_t seed,uint64_t *slot);
extern const unsigned char gc_probe_memory_program_end[];
static double seconds(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9; }
bool guest_cpu_probe(FILE *log,unsigned iterations) {
    const uint64_t base=0x100000000,done=0xffff0000;
    GuestMemory memory={0};GuestCPU *cpu=calloc(1,sizeof *cpu);
    if(!cpu)return false;
    size_t size=(uintptr_t)gc_probe_program_end-(uintptr_t)gc_probe_program;
    bool ok=false;
    if(size>GM_PAGE_SIZE || gm_map(&memory,base,GM_PAGE_SIZE,GM_READ|GM_EXEC,7,false,false)!=GM_OK ||
        gm_populate(&memory,base,(const void *)gc_probe_program,size)!=GM_OK)goto end;
    // Independent C reference and native assembler must agree before timing.
    for(unsigned n=0;n<100;n++) {
        uint64_t seed=UINT64_MAX-n,expected=seed;
        for(unsigned k=0;k<n;k++) { expected=expected*1664525+1013904223;expected^=expected>>13; }
        gc_reset(cpu,base,0);cpu->x[0]=n;cpu->x[1]=seed;cpu->x[30]=done;
        if(gc_run(cpu,&memory,4*n+7,done)!=GC_RETURNED || cpu->x[0]!=expected || gc_probe_program(n,seed)!=expected) {
            fprintf(log,"CPU differential check failed at n=%u pc=%#" PRIx64 "\n",n,cpu->pc);goto end;
        }
    }
    gc_reset(cpu,base,0);cpu->x[0]=iterations;cpu->x[1]=42;cpu->x[30]=done;
    double start=seconds();GCResult result=gc_run(cpu,&memory,(uint64_t)iterations*4+7,done);double interpreted=seconds()-start;
    start=seconds();uint64_t expected=gc_probe_program(iterations,42);double native=seconds()-start;
    ok=result==GC_RETURNED && cpu->x[0]==expected;
    fprintf(log,"CPU data-only execution %s: %s, instructions=%" PRIu64 ", result=%#" PRIx64 "\n",ok?"PASS":"FAIL",gc_result_string(result),cpu->retired,cpu->x[0]);
    fprintf(log,"interpreter %.6fs, %.2f million guest instructions/s; native %.6fs; slowdown %.2fx\n",interpreted,cpu->retired/interpreted/1e6,native,interpreted/native);
    if(!ok)goto end;
    size=(uintptr_t)gc_probe_memory_program_end-(uintptr_t)gc_probe_memory_program;
    if(size>GM_PAGE_SIZE || gm_map(&memory,0x4000,GM_PAGE_SIZE,3,3,false,false)!=GM_OK ||
        gm_populate(&memory,base,(const void *)gc_probe_memory_program,size)!=GM_OK) {ok=false;goto end;}
    gc_reset(cpu,base,0);cpu->x[0]=iterations;cpu->x[1]=42;cpu->x[2]=0x4000;cpu->x[30]=done;
    start=seconds();result=gc_run(cpu,&memory,(uint64_t)iterations*5+3,done);interpreted=seconds()-start;
    uint64_t slot=0,guestSlot=0;
    start=seconds();expected=gc_probe_memory_program(iterations,42,&slot);native=seconds()-start;
    ok=result==GC_RETURNED && cpu->x[0]==expected && expected==42+(uint64_t)iterations &&
        gm_read(&memory,0x4000,&guestSlot,8)==GM_OK && guestSlot==slot;
    fprintf(log,"CPU load/store %s: instructions=%" PRIu64 ", result=%#" PRIx64 ", stored=%#" PRIx64 "\n",ok?"PASS":"FAIL",cpu->retired,cpu->x[0],guestSlot);
    fprintf(log,"interpreter %.6fs, %.2f million guest instructions/s; native %.6fs; slowdown %.2fx\n",interpreted,cpu->retired/interpreted/1e6,native,interpreted/native);
    fprintf(log,"Scalar loops only. No vector, native API bridge, game startup, frame-rate or iPad performance claim.\n");
end:
    gm_destroy(&memory);free(cpu);return ok;
}
