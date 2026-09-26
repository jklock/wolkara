#include "NativeGuestPolicy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    const char *queries[]={"hw.ncpu","hw.activecpu","hw.logicalcpu","hw.logicalcpu_max",
        "hw.physicalcpu","hw.physicalcpu_max"};
    for(unsigned i=0;i<sizeof queries/sizeof *queries;i++) {
        struct { int count,guard; } result={10,12345};
        assert(ng_limit_cpu_answer(queries[i],&result.count,sizeof(int),2));
        assert(result.count==2 && result.guard==12345);
        assert(!ng_limit_cpu_answer(queries[i],&result.count,sizeof(int),8) && result.count==2);
    }
    int count=10;
    assert(!ng_limit_cpu_answer("hw.ncpu",&count,sizeof count,0) && count==10);
    assert(!ng_limit_cpu_answer("hw.memsize",&count,sizeof count,2) && count==10);
    assert(!ng_limit_cpu_answer("hw.ncpu",&count,sizeof count-1,2) && count==10);
    assert(!ng_limit_cpu_answer("hw.ncpu",NULL,sizeof count,2));
    assert(!ng_limit_cpu_answer(NULL,&count,sizeof count,2));
    count=-1;assert(!ng_limit_cpu_answer("hw.ncpu",&count,sizeof count,2) && count==-1);
    int mib[]={CTL_HW,HW_NCPU,0};
    assert(!strcmp(ng_cpu_mib_name(mib,2),"hw.ncpu"));
    mib[1]=HW_AVAILCPU;assert(!strcmp(ng_cpu_mib_name(mib,2),"hw.activecpu"));
    mib[1]=HW_PAGESIZE;assert(!ng_cpu_mib_name(mib,2));
    mib[0]=CTL_KERN;mib[1]=HW_NCPU;assert(!ng_cpu_mib_name(mib,2));
    assert(!ng_cpu_mib_name(NULL,2) && !ng_cpu_mib_name(mib,1) && !ng_cpu_mib_name(mib,3));
    assert(ng_limit_cpu_sysconf(_SC_NPROCESSORS_CONF,10,2)==2);
    assert(ng_limit_cpu_sysconf(_SC_NPROCESSORS_ONLN,10,2)==2);
    assert(ng_limit_cpu_sysconf(_SC_NPROCESSORS_ONLN,2,10)==2);
    assert(ng_limit_cpu_sysconf(_SC_NPROCESSORS_ONLN,10,0)==10);
    assert(ng_limit_cpu_sysconf(_SC_NPROCESSORS_ONLN,-1,2)==-1);
    assert(ng_limit_cpu_sysconf(_SC_NPROCESSORS_ONLN,0,2)==0);
    assert(ng_limit_cpu_sysconf(_SC_PAGESIZE,16384,2)==16384);
    // A build made for one executable never stubs that executable's imports.
    assert(!ng_may_stub(false, false, false));
    // A generic build does, and a carried library's imports are stubbed in any build.
    assert(ng_may_stub(true, false, false));
    assert(ng_may_stub(false, true, false));
    assert(ng_may_stub(true, true, false));
    // A weak import that nothing provides stays null.
    for (unsigned i = 0; i < 4; i++) assert(!ng_may_stub(i & 1, i & 2, true));

    // Nothing reserved: nothing to decide.
    assert(ng_reserved_choice(true, false, 1, 0) == NG_RESERVED_NONE);
    assert(ng_reserved_choice(false, false, 1, 0) == NG_RESERVED_NONE);
    // External JIT takes a reservation the image fits in, up to its last byte.
    assert(ng_reserved_choice(true, true, 4096, 8192) == NG_RESERVED_TAKE);
    assert(ng_reserved_choice(true, true, 8192, 8192) == NG_RESERVED_TAKE);
    // Too small: refused, not replaced by a region nothing prepared.
    assert(ng_reserved_choice(true, true, 8193, 8192) == NG_RESERVED_REFUSE);
    // Another route gives it back, whatever its size.
    assert(ng_reserved_choice(false, true, 4096, 8192) == NG_RESERVED_GIVE_BACK);
    assert(ng_reserved_choice(false, true, 16384, 8192) == NG_RESERVED_GIVE_BACK);

    puts("PASS: runtime stubs only where no build-time analysis covered an import; reserved arena taken, refused or given back");
}
