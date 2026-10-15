#include "GuestExclusive.h"
#include <string.h>

bool gm_exclusive_instruction(uint32_t i) {
    return (i & 0x3f800000) == 0x08000000 &&
           (!((i >> 21) & 1) || (i >> 30) >= 2);
}
static uint64_t get(const GCRegisters *r,unsigned n,bool stack) {
    return n<31?r->x[n]:stack?r->sp:0;
}
static GMMemoryStep exclusive(GMSparseMemory *memory,uint32_t i,GCRegisters *r,
                              GMSparseExclusive *monitor,GMResult *fault,bool *finished) {
    unsigned rt=i&31,rn=(i>>5)&31,rt2=(i>>10)&31,rs=(i>>16)&31;
    bool pair=(i>>21)&1,load=(i>>22)&1;
    unsigned size=1u<<(i>>30),count=pair?2:1;
    if((!pair && rt2!=31) || (load && rs!=31) || (load && pair && rt==rt2) ||
       (!load && rs!=31 && (rs==rn || rs==rt || (pair && rs==rt2)))) return GM_STEP_UNSUPPORTED;
    if((rn==31 && (r->sp&15)) || (r->pc&3) || r->pc>UINT64_MAX-4) {
        *fault=GM_INVALID;return GM_STEP_FAULT;
    }
    uint64_t address=get(r,rn,true);
    unsigned char bytes[16]={0};
    if(load) {
        *fault=gm_sparse_load_exclusive(memory,address,bytes,size*count,monitor);
        if(*fault!=GM_OK)return GM_STEP_FAULT;
        for(unsigned part=0;part<count;part++) {
            uint64_t value=0;
            for(unsigned j=0;j<size;j++)value|=(uint64_t)bytes[part*size+j]<<(j*8);
            unsigned index=part?rt2:rt;
            if(index!=31)r->x[index]=value;
        }
    } else {
        for(unsigned part=0;part<count;part++) {
            uint64_t value=get(r,part?rt2:rt,false);
            for(unsigned j=0;j<size;j++)bytes[part*size+j]=(unsigned char)(value>>(j*8));
        }
        bool stored=false;
        *fault=gm_sparse_store_exclusive(memory,address,bytes,size*count,monitor,&stored);
        if(*fault!=GM_OK)return GM_STEP_FAULT;
        if(rs!=31)r->x[rs]=stored?0:1;
        *finished=true;
    }
    r->pc+=4;
    return GM_STEP_OK;
}
GMMemoryStep gm_exclusive_sequence(GMSparseMemory *memory,uint32_t first,
                                   GCRegisters *registers,GMInstructionFetch fetch,
                                   void *context,GMResult *fault,GMExclusiveDiagnostic *diagnostic) {
    if(!registers || !fetch || !fault || !gm_exclusive_instruction(first)) return GM_STEP_UNSUPPORTED;
    GCRegisters r=*registers;
    if(r.pc>UINT64_MAX-128) { *fault=GM_INVALID;return GM_STEP_FAULT; }
    uint64_t start=r.pc;
    GMSparseExclusive monitor={0};
    uint32_t instruction=first;
    for(unsigned step=0;step<32;step++) {
        if(diagnostic) { diagnostic->pc=r.pc;diagnostic->reason="[software-vm] exclusive encoding at "; }
        bool finished=false;
        if(gm_exclusive_instruction(instruction)) {
            GMMemoryStep result=exclusive(memory,instruction,&r,&monitor,fault,&finished);
            if(result!=GM_STEP_OK)return result;
        } else if((instruction&0xfffff0ff)==0xd503305f) {
            // CLREX ends the monitor. A later native store-exclusive will trap
            // separately and fail, exactly as an open monitor requires.
            r.pc+=4;finished=true;
        } else if(!gc_register_step(&r,instruction)) {
            // A supported scalar access may occur inside an exclusive sequence.
            // Reads can continue with the current monitor. Any write ends this
            // runtime operation, so a later rejection never rolls back a write.
            GMMemoryRegisters access={0};
            memcpy(access.x,r.x,sizeof r.x);access.sp=r.sp;access.pc=r.pc;
            GMMemoryStep access_result=GM_STEP_UNSUPPORTED;
            if(!(instruction&(1u<<26))) access_result=gm_memory_step(memory,instruction,&access,fault);
            if(access_result==GM_STEP_OK) {
                memcpy(r.x,access.x,sizeof r.x);r.sp=access.sp;r.pc=access.pc;
                bool ordered=(instruction&0x3f9ffc00)==0x089ffc00;
                bool rcpc=(instruction&0x3ffffc00)==0x38bfc000;
                bool single=(instruction&0x3b000000)==0x39000000 || (instruction&0x3b000000)==0x38000000;
                bool pair=(instruction&0x3a000000)==0x28000000;
                bool load=rcpc || (ordered && (instruction&(1u<<22))) ||
                          (single && ((instruction>>22)&3)) || (pair && (instruction&(1u<<22)));
                // LSE read-modify-write instructions share the single-access
                // major group; treat all of them as writes.
                if(!rcpc && (instruction&0x3f200c00)==0x38200000)load=false;
                finished=!load;
            } else {
                if(diagnostic) {
                    diagnostic->reason="[software-vm] register operation at ";
                    if((instruction&0x1f800000)==0x13000000) diagnostic->reason="[software-vm] bitfield operation at ";
                    else if((instruction&0x1f800000)==0x13800000) diagnostic->reason="[software-vm] extract operation at ";
                    else if((instruction&0x3b000000)==0x39000000 || (instruction&0x3b000000)==0x38000000)
                        diagnostic->reason=(instruction&(1u<<22))?"intervening single load at ":"intervening single store at ";
                    else if((instruction&0x3a000000)==0x28000000)
                        diagnostic->reason=(instruction&(1u<<22))?"intervening pair load at ":"intervening pair store at ";
                    else if((instruction&0x3f000000)==0x08000000) diagnostic->reason="intervening ordered operation at ";
                    else if((instruction&0x0a000000)==0x08000000) diagnostic->reason="intervening other memory operation at ";
                    else if((instruction&0xfffff01f)==0xd503201f) diagnostic->reason="[software-vm] hint operation at ";
                }
                return access_result;
            }
        }
        if(finished || r.pc<start || r.pc>=start+128) {
            *registers=r;*fault=GM_OK;return GM_STEP_OK;
        }
        if(!fetch(r.pc,&instruction,context)) { *fault=GM_INVALID;return GM_STEP_FAULT; }
    }
    if(diagnostic) diagnostic->reason="[software-vm] exclusive step budget at ";
    return GM_STEP_UNSUPPORTED;
}
