#include "CPUProbe.h"
int main(void) { return guest_cpu_probe(stdout,2000000)?0:1; }
