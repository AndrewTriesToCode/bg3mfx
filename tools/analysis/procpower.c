// Process power and CPU split by core tier, from proc_pid_rusage (no root).
// usage: procpower PID [seconds] [samples]
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>

static int usage(int pid, struct rusage_info_v6 *r) {
    return proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)r);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: procpower PID [seconds] [samples]\n"); return 2; }
    int pid = atoi(argv[1]), seconds = argc > 2 ? atoi(argv[2]) : 5, samples = argc > 3 ? atoi(argv[3]) : 1;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double toSec = (double)tb.numer / tb.denom / 1e9;
    struct rusage_info_v6 a, b;
    if (usage(pid, &a)) { perror("proc_pid_rusage"); return 1; }
    for (int i = 0; i < samples; ++i) {
        uint64_t t0 = mach_absolute_time();
        sleep(seconds);
        if (usage(pid, &b)) { perror("proc_pid_rusage"); return 1; }
        double wall = (mach_absolute_time() - t0) * toSec;
        double cpu = ((b.ri_user_time - a.ri_user_time) + (b.ri_system_time - a.ri_system_time)) * toSec;
        double pcpu = ((b.ri_user_ptime - a.ri_user_ptime) + (b.ri_system_ptime - a.ri_system_ptime)) * toSec;
        double energy = (b.ri_energy_nj - a.ri_energy_nj) / 1e9, penergy = (b.ri_penergy_nj - a.ri_penergy_nj) / 1e9;
        printf("cpu %5.0f%%  top-tier %5.0f%% (%2.0f%% of cpu)  power %5.2f W  top-tier %5.2f W\n",
               100 * cpu / wall, 100 * pcpu / wall, cpu ? 100 * pcpu / cpu : 0, energy / wall, penergy / wall);
        a = b;
    }
    return 0;
}
