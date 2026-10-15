// Per-thread CPU use of a process, by thread name, from proc_pidinfo (no root
// needed for the user's own processes). Unlike `sample`, which also records
// threads that are runnable but waiting for a core, this is CPU time consumed.
// usage: threadcpu PID [seconds]
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <time.h>
#include <unistd.h>

typedef struct { uint64_t id, ns; int pri, curpri; char name[64]; } Thread;

static int snapshot(int pid, Thread *out, int cap) {
    static uint64_t ids[4096];
    int bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, ids, sizeof ids);
    if (bytes <= 0) return -1;
    int n = 0;
    for (int i = 0; i < bytes / (int)sizeof(uint64_t) && n < cap; ++i) {
        struct proc_threadinfo info;
        if (proc_pidinfo(pid, PROC_PIDTHREADINFO, ids[i], &info, sizeof info) != sizeof info) continue;
        out[n].id = ids[i];
        out[n].ns = info.pth_user_time + info.pth_system_time;
        out[n].pri = info.pth_priority;
        out[n].curpri = info.pth_curpri;
        strlcpy(out[n].name, info.pth_name, sizeof out[n].name);
        ++n;
    }
    return n;
}

typedef struct { double use; int index; } Row;

static int byUse(const void *a, const void *b) {
    double x = ((const Row *)a)->use, y = ((const Row *)b)->use;
    return x < y ? 1 : x > y ? -1 : 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: threadcpu PID [seconds]\n"); return 2; }
    int pid = atoi(argv[1]);
    double seconds = argc > 2 ? atof(argv[2]) : 5;
    static Thread a[4096], b[4096];
    static Row rows[4096];
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int na = snapshot(pid, a, 4096);
    usleep((useconds_t)(seconds * 1e6));
    int nb = snapshot(pid, b, 4096);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (na < 0 || nb < 0) { perror("proc_pidinfo"); return 1; }
    double wall = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9, total = 0;
    int n = 0;
    for (int i = 0; i < nb; ++i)
        for (int j = 0; j < na; ++j)
            if (a[j].id == b[i].id) {
                rows[n].use = (b[i].ns - a[j].ns) / 1e9 / wall * 100;
                rows[n++].index = i;
                break;
            }
    qsort(rows, n, sizeof rows[0], byUse);
    for (int i = 0; i < n; ++i) total += rows[i].use;
    printf("%6s %4s %4s  thread (total %.0f%% over %.1f s)\n", "cpu%", "pri", "cur", total, wall);
    for (int i = 0; i < n && rows[i].use >= 1; ++i) {
        const Thread *t = &b[rows[i].index];
        printf("%6.1f %4d %4d  %s\n", rows[i].use, t->pri, t->curpri, t->name[0] ? t->name : "(unnamed)");
    }
    return 0;
}
