#include "GuestCPU.h"
#include <string.h>

enum { INVALID, NOP, WIDE, ADD_IMM, ADD_REG, LOGIC, MADD, BRANCH, BRANCH_REG,
       COND, CBZ, ADDRESS, LOAD, STORE };
static uint64_t sign_extend(uint64_t x, unsigned bits) {
    uint64_t sign=UINT64_C(1)<<(bits-1); return (x^sign)-sign;
}
static uint64_t mask(unsigned width) { return width==64 ? UINT64_MAX : UINT32_MAX; }
static uint64_t reg(const GuestCPU *c,unsigned r,bool sp) { return r<31 ? c->x[r] : sp ? c->sp : 0; }
static void put(GuestCPU *c,unsigned r,uint64_t value,unsigned width,bool sp) {
    value &= mask(width);
    if (r<31) c->x[r]=value; else if (sp) c->sp=value;
}
static uint64_t shifted(uint64_t value,unsigned type,unsigned amount,unsigned width) {
    value &= mask(width);
    if (!amount) return value;
    if (type==0) return (value<<amount)&mask(width);
    if (type==1) return value>>amount;
    if (type==2) return (value>>amount) | ((value>>(width-1)) ? (mask(width)<<(width-amount))&mask(width) : 0);
    return ((value>>amount)|(value<<(width-amount)))&mask(width);
}
static bool condition(uint8_t flags,unsigned cond) {
    bool n=flags&8,z=flags&4,c=flags&2,v=flags&1,result;
    switch (cond>>1) {
        case 0:result=z;break; case 1:result=c;break; case 2:result=n;break;
        case 3:result=v;break; case 4:result=c&&!z;break; case 5:result=n==v;break;
        case 6:result=!z&&(n==v);break; default:return true;
    }
    return (cond&1) ? !result : result;
}
static uint64_t arithmetic(GuestCPU *c,uint64_t a,uint64_t b,bool sub,bool flags,unsigned width) {
    uint64_t m=mask(width),sign=UINT64_C(1)<<(width-1); a&=m;b&=m;
    uint64_t result=(sub?a-b:a+b)&m;
    if (flags) {
        bool carry=sub?a>=b:result<a;
        bool overflow=((sub?(a^b):~(a^b))&(a^result)&sign)!=0;
        c->nzcv=(result&sign?8:0)|(result==0?4:0)|(carry?2:0)|(overflow?1:0);
    }
    return result;
}
static GCDecoded decode(uint64_t pc,uint32_t i) {
    GCDecoded d={.pc=pc,.instruction=i,.rd=i&31,.rn=(i>>5)&31,.rm=(i>>16)&31,
        .ra=(i>>10)&31,.width=(i>>31)?64:32,.valid=true};
    if (i==0xd503201f) d.op=NOP;
    else if ((i&0x1f800000)==0x12800000) {
        d.flags=(i>>29)&3; d.amount=((i>>21)&3)*16;
        if (d.flags!=1 && d.amount<d.width) { d.op=WIDE; d.immediate=(uint64_t)((i>>5)&65535)<<d.amount; }
    } else if ((i&0x1f800000)==0x11000000) {
        d.op=ADD_IMM;d.flags=(i>>29)&3;d.immediate=((i>>10)&4095)<<(((i>>22)&1)*12);
    } else if ((i&0x1f200000)==0x0b000000) {
        d.shift=(i>>22)&3;d.amount=(i>>10)&63;d.flags=(i>>29)&3;
        if (d.shift!=3 && d.amount<d.width) d.op=ADD_REG;
    } else if ((i&0x1f000000)==0x0a000000) {
        d.shift=(i>>22)&3;d.amount=(i>>10)&63;d.flags=((i>>29)&3)|(((i>>21)&1)<<2);
        if (d.amount<d.width) d.op=LOGIC;
    } else if ((i&0x7fe00000)==0x1b000000) { d.op=MADD;d.flags=(i>>15)&1; }
    else if ((i&0x7c000000)==0x14000000) {
        d.op=BRANCH; d.flags=i>>31; d.immediate=pc+sign_extend(i&0x3ffffff,26)*4;
    } else if ((i&0xfffffc1f)==0xd61f0000 || (i&0xfffffc1f)==0xd63f0000 || (i&0xfffffc1f)==0xd65f0000) {
        d.op=BRANCH_REG; d.flags=(i&0xfffffc1f)==0xd63f0000;
    } else if ((i&0xff000010)==0x54000000) {
        d.op=COND;d.flags=i&15;d.immediate=pc+sign_extend((i>>5)&0x7ffff,19)*4;
    } else if ((i&0x7e000000)==0x34000000) {
        d.op=CBZ;d.flags=(i>>24)&1;d.immediate=pc+sign_extend((i>>5)&0x7ffff,19)*4;
    } else if ((i&0x1f000000)==0x10000000) {
        d.op=ADDRESS; d.width=64;
        uint64_t offset=sign_extend(((uint64_t)(i>>5)&0x7ffff)*4+((i>>29)&3),21);
        d.immediate=(i>>31)?(pc&~UINT64_C(4095))+offset*4096:pc+offset;
    } else if ((i&0x3b000000)==0x39000000 && !(i&(1u<<26))) {
        unsigned opc=(i>>22)&3;
        if (opc<=1) { d.op=opc?LOAD:STORE;d.amount=1u<<(i>>30);d.width=d.amount==8?64:32;
            d.immediate=(uint64_t)((i>>10)&4095)*d.amount; }
    }
    return d;
}
void gc_reset(GuestCPU *c,uint64_t entry,uint64_t stack) {
    memset(c,0,sizeof *c);c->pc=entry;c->sp=stack;c->thread.jit_write_protected=true;
}
GCResult gc_run(GuestCPU *c,GuestMemory *m,uint64_t budget,uint64_t return_pc) {
    for (uint64_t step=0;step<budget;step++) {
        if (c->pc==return_pc) return GC_RETURNED;
        if (c->cache_generation!=m->code_generation || c->cache_write_protected!=c->thread.jit_write_protected) {
            memset(c->cache,0,sizeof c->cache);
            c->cache_generation=m->code_generation;c->cache_write_protected=c->thread.jit_write_protected;
        }
        GCDecoded *d=&c->cache[(c->pc>>2)&(GC_CACHE_SIZE-1)];
        if (!d->valid || d->pc!=c->pc) {
            uint32_t i; c->memory_result=gm_fetch(m,&c->thread,c->pc,&i);
            if (c->memory_result!=GM_OK) return GC_MEMORY;
            *d=decode(c->pc,i);
        }
        uint64_t next=c->pc+4,a,b,value=0;bool write=false,sp=false;
        switch (d->op) {
            case NOP:break;
            case WIDE:
                value=d->flags==0?~d->immediate:d->flags==2?d->immediate:
                    (reg(c,d->rd,false)&~(UINT64_C(65535)<<d->amount))|d->immediate;
                write=true;break;
            case ADD_IMM:case ADD_REG:
                a=reg(c,d->rn,d->op==ADD_IMM);
                b=d->op==ADD_IMM?d->immediate:shifted(reg(c,d->rm,false),d->shift,d->amount,d->width);
                value=arithmetic(c,a,b,d->flags&2,d->flags&1,d->width);
                write=true;sp=d->op==ADD_IMM && !(d->flags&1);break;
            case LOGIC:
                a=reg(c,d->rn,false);b=shifted(reg(c,d->rm,false),d->shift,d->amount,d->width);
                if (d->flags&4) b=~b;
                value=(d->flags&3)==1?a|b:(d->flags&3)==2?a^b:a&b;
                value&=mask(d->width);
                if ((d->flags&3)==3) c->nzcv=(value>>(d->width-1)?8:0)|(value==0?4:0);
                write=true;break;
            case MADD:
                value=reg(c,d->rn,false)*reg(c,d->rm,false);
                value=d->flags?reg(c,d->ra,false)-value:reg(c,d->ra,false)+value;write=true;break;
            case BRANCH:next=d->immediate;if(d->flags)c->x[30]=c->pc+4;break;
            case BRANCH_REG:next=reg(c,d->rn,false);if(d->flags)c->x[30]=c->pc+4;break;
            case COND:if(condition(c->nzcv,d->flags))next=d->immediate;break;
            case CBZ:if(((reg(c,d->rd,false)&mask(d->width))!=0)==(d->flags!=0))next=d->immediate;break;
            case ADDRESS:value=d->immediate;write=true;break;
            case LOAD:case STORE: {
                unsigned char bytes[8]={0};a=reg(c,d->rn,true)+d->immediate;
                if(d->op==STORE) {
                    b=reg(c,d->rd,false);
                    for(unsigned j=0;j<d->amount;j++)bytes[j]=(unsigned char)(b>>(j*8));
                    c->memory_result=gm_write(m,&c->thread,a,bytes,d->amount);
                } else {
                    c->memory_result=gm_read(m,a,bytes,d->amount);
                    for(unsigned j=0;j<d->amount;j++)value|=(uint64_t)bytes[j]<<(j*8);
                    write=true;
                }
                if(c->memory_result!=GM_OK)return GC_MEMORY;
                break;
            }
            default:c->fault_instruction=d->instruction;return GC_UNSUPPORTED;
        }
        if(write)put(c,d->rd,value,d->width,sp);
        c->pc=next;c->retired++;
    }
    return c->pc==return_pc?GC_RETURNED:GC_BUDGET;
}
const char *gc_result_string(GCResult r) {
    switch(r) {
        case GC_BUDGET:return "instruction budget reached";
        case GC_RETURNED:return "returned";
        case GC_UNSUPPORTED:return "unsupported instruction";
        case GC_MEMORY:return "guest memory fault";
    }
    return "unknown CPU result";
}
