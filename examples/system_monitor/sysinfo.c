/* sysinfo.c -- the real numbers behind examples/system_monitor.
 *
 * The monitor draws live CPU load, memory use, network throughput, disk space
 * and the busiest processes of the machine it runs on. Everything here is read
 * from the operating system: mach host statistics, sysctl and libproc on
 * macOS, /proc on Linux. Windows has no implementation yet, so sys_sample()
 * returns false there and the monitor says so instead of inventing numbers.
 *
 * main.build compiles this with the program; the extern fn declarations in
 * main.goose are the other half of the contract:
 *
 *     extern fn sys_sample() -> bool
 *     extern fn sys_cpu_usage() -> f64             0..1 since the last sample
 *     extern fn sys_mem_used() -> u64              bytes
 *     extern fn sys_mem_total() -> u64             bytes
 *     extern fn sys_load_average(index: i64) -> f64
 *     extern fn sys_uptime() -> f64                seconds
 *     extern fn sys_disk(path: const u8[:], free: u64&, total: u64&) -> bool
 *     extern fn sys_net_bytes(rx: u64&, tx: u64&) -> bool   cumulative
 *     extern fn sys_process_count() -> i64
 *     extern fn sys_process(i: i64, name: u8[:], cpu: f64&, mem: u64&,
 *                           threads: i64&) -> bool
 *
 * The process list is refreshed by sys_sample(), which keeps the previous
 * CPU time of every pid so `cpu` is a real rate rather than a lifetime
 * average. Output pointers are written element by element: a Goose caller may
 * pass a field of a packed struct, so nothing here may assume 8-byte (or any)
 * alignment or write more than it was asked to.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(__APPLE__)

#include <libproc.h>
#include <mach/mach.h>
#include <sys/statvfs.h>
#include <sys/sysctl.h>
#include <unistd.h>

#elif defined(__linux__)

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/statvfs.h>
#include <unistd.h>

#endif

#define MAX_TRACKED 2048
#define MAX_REPORTED 128

/* --- values written through a caller pointer ----------------------------
 * A store per element through memcpy, never a wider write than the object:
 * the caller's pointer may be a field of a packed Goose struct. */
static void store_f64(double *p, double v) { memcpy(p, &v, sizeof v); }
static void store_u64(uint64_t *p, uint64_t v) { memcpy(p, &v, sizeof v); }
static void store_i64(int64_t *p, int64_t v) { memcpy(p, &v, sizeof v); }

static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* --- state --------------------------------------------------------------- */

struct proc_sample {
    uint64_t pid;
    char name[40];
    double cpu;      /* 0..1 of the whole machine since the previous sample */
    uint64_t mem;    /* resident bytes */
    int64_t threads;
};

static struct {
    bool ready;
    double cpu;         /* 0..1 */
    uint64_t mem_used;
    uint64_t mem_total;
    double load[3];
    double uptime;
    uint64_t net_rx;    /* cumulative bytes */
    uint64_t net_tx;
    bool net_ok;
    int64_t proc_count;
    struct proc_sample procs[MAX_REPORTED];
} g;

/* Previous CPU time per pid, so a probe can turn it into a rate. */
static struct {
    uint64_t pid;
    uint64_t ticks;    /* nanoseconds of CPU time */
} g_prev[MAX_TRACKED];
static int64_t g_prev_count;

static void copy_name(char *dst, size_t cap, const char *src) {
    size_t i = 0;
    if (src) {
        for (; i + 1 < cap && src[i]; i++) dst[i] = src[i];
    }
    for (; i < cap; i++) dst[i] = 0;
}

static void note_prev(uint64_t pid, uint64_t ticks) {
    for (int64_t i = 0; i < g_prev_count; i++) {
        if (g_prev[i].pid == pid) {
            g_prev[i].ticks = ticks;
            return;
        }
    }
    if (g_prev_count < MAX_TRACKED) {
        g_prev[g_prev_count].pid = pid;
        g_prev[g_prev_count].ticks = ticks;
        g_prev_count++;
    }
}

/* The CPU time the previous sample saw for this pid, and a flag saying
 * whether there was one: a process seen for the first time has no rate yet. */
static bool prev_ticks(uint64_t pid, uint64_t *out) {
    for (int64_t i = 0; i < g_prev_count; i++) {
        if (g_prev[i].pid == pid) {
            *out = g_prev[i].ticks;
            return true;
        }
    }
    return false;
}

static void insert_process(const struct proc_sample *p) {
    /* Sorted by CPU, highest first, and only the top MAX_REPORTED are kept. */
    int64_t at = g.proc_count;
    if (at >= MAX_REPORTED) {
        if (p->cpu <= g.procs[MAX_REPORTED - 1].cpu) return;
        at = MAX_REPORTED - 1;
    } else {
        g.proc_count++;
    }
    while (at > 0 && g.procs[at - 1].cpu < p->cpu) {
        g.procs[at] = g.procs[at - 1];
        at--;
    }
    g.procs[at] = *p;
}

/* --- macOS --------------------------------------------------------------- */

#if defined(__APPLE__)

static uint64_t g_prev_busy, g_prev_total;

static void sample_cpu(void) {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) !=
        KERN_SUCCESS)
        return;
    uint64_t busy = (uint64_t)info.cpu_ticks[CPU_STATE_USER] +
                    (uint64_t)info.cpu_ticks[CPU_STATE_SYSTEM] +
                    (uint64_t)info.cpu_ticks[CPU_STATE_NICE];
    uint64_t total = busy + (uint64_t)info.cpu_ticks[CPU_STATE_IDLE];
    uint64_t d_busy = busy - g_prev_busy;
    uint64_t d_total = total - g_prev_total;
    if (g_prev_total != 0 && d_total > 0) g.cpu = (double)d_busy / (double)d_total;
    g_prev_busy = busy;
    g_prev_total = total;
}

static void sample_memory(void) {
    uint64_t total = 0;
    size_t len = sizeof total;
    if (sysctlbyname("hw.memsize", &total, &len, NULL, 0) == 0) g.mem_total = total;

    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) !=
        KERN_SUCCESS)
        return;
    uint64_t page = (uint64_t)vm_kernel_page_size;
    /* Wired and compressed pages are not reclaimable, an inactive page may be:
     * that sum is what Activity Monitor calls "Memory Used". */
    uint64_t used = ((uint64_t)vm.active_count + (uint64_t)vm.wire_count +
                     (uint64_t)vm.compressor_page_count) *
                    page;
    g.mem_used = used;
}

static void sample_load_and_uptime(void) {
    double avg[3] = {0.0, 0.0, 0.0};
    if (getloadavg(avg, 3) > 0) {
        g.load[0] = avg[0];
        g.load[1] = avg[1];
        g.load[2] = avg[2];
    }
    struct timeval boot;
    size_t len = sizeof boot;
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boot, &len, NULL, 0) == 0) {
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        g.uptime = (double)(now.tv_sec - boot.tv_sec) +
                   (double)(now.tv_nsec / 1000 - boot.tv_usec) / 1e6;
    }
}

static void sample_network(void) {
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0 || len == 0) return;
    char *buf = (char *)malloc(len);
    if (!buf) return;
    if (sysctl(mib, 6, buf, &len, NULL, 0) != 0) {
        free(buf);
        return;
    }
    uint64_t rx = 0, tx = 0;
    char *end = buf + len;
    for (char *p = buf; p + sizeof(struct if_msghdr) <= end;) {
        struct if_msghdr *msg = (struct if_msghdr *)p;
        if (msg->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *m2 = (struct if_msghdr2 *)p;
            rx += (uint64_t)m2->ifm_data.ifi_ibytes;
            tx += (uint64_t)m2->ifm_data.ifi_obytes;
        }
        if (msg->ifm_msglen <= 0) break;
        p += msg->ifm_msglen;
    }
    free(buf);
    g.net_rx = rx;
    g.net_tx = tx;
    g.net_ok = true;
}

static void sample_processes(double elapsed) {
    pid_t pids[MAX_TRACKED];
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)sizeof pids);
    if (bytes <= 0) return;
    int count = bytes / (int)sizeof(pid_t);
    g.proc_count = 0;

    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct proc_taskinfo ti;
        int got = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, (int)sizeof ti);
        if (got != (int)sizeof ti) continue;

        struct proc_sample s;
        memset(&s, 0, sizeof s);
        s.pid = (uint64_t)pid;
        char name[64] = {0};
        if (proc_name(pid, name, (int)sizeof name) <= 0) {
            /* Kernel and helper tasks may have no name of their own. */
            strncpy(name, "?", sizeof name - 1);
        }
        copy_name(s.name, sizeof s.name, name);
        s.mem = (uint64_t)ti.pti_resident_size;
        s.threads = (int64_t)ti.pti_threadnum;
        uint64_t ticks = (uint64_t)ti.pti_total_user + (uint64_t)ti.pti_total_system;
        uint64_t before = 0;
        if (elapsed > 0.0 && prev_ticks((uint64_t)pid, &before) && ticks > before)
            s.cpu = (double)(ticks - before) / (elapsed * 1e9);
        note_prev((uint64_t)pid, ticks);
        insert_process(&s);
    }
}

/* --- Linux --------------------------------------------------------------- */

#elif defined(__linux__)

static uint64_t g_prev_busy, g_prev_total;

static bool read_line(const char *path, char *out, size_t cap) {
    FILE *f = fopen(path, "r");
    if (!f) return false;
    size_t n = fread(out, 1, cap - 1, f);
    fclose(f);
    out[n] = 0;
    return n > 0;
}

static void sample_cpu(void) {
    char buf[512];
    if (!read_line("/proc/stat", buf, sizeof buf)) return;
    unsigned long long user = 0, nice = 0, system = 0, idle = 0, iowait = 0, irq = 0,
                        softirq = 0, steal = 0;
    if (sscanf(buf, "cpu %llu %llu %llu %llu %llu %llu %llu %llu", &user, &nice, &system,
               &idle, &iowait, &irq, &softirq, &steal) < 4)
        return;
    uint64_t busy = user + nice + system + irq + softirq + steal;
    uint64_t total = busy + idle + iowait;
    uint64_t d_busy = busy - g_prev_busy;
    uint64_t d_total = total - g_prev_total;
    if (g_prev_total != 0 && d_total > 0) g.cpu = (double)d_busy / (double)d_total;
    g_prev_busy = busy;
    g_prev_total = total;
}

static void sample_memory(void) {
    char buf[4096];
    if (!read_line("/proc/meminfo", buf, sizeof buf)) return;
    unsigned long long total = 0, available = 0;
    for (char *line = buf; line && *line;) {
        char *next = strchr(line, '\n');
        if (sscanf(line, "MemTotal: %llu kB", &total) == 1) {
        } else if (sscanf(line, "MemAvailable: %llu kB", &available) == 1) {
        }
        line = next ? next + 1 : NULL;
    }
    if (total > 0) {
        g.mem_total = total * 1024ull;
        g.mem_used = (total - (available < total ? available : total)) * 1024ull;
    }
}

static void sample_load_and_uptime(void) {
    char buf[256];
    if (read_line("/proc/loadavg", buf, sizeof buf))
        sscanf(buf, "%lf %lf %lf", &g.load[0], &g.load[1], &g.load[2]);
    if (read_line("/proc/uptime", buf, sizeof buf)) sscanf(buf, "%lf", &g.uptime);
}

static void sample_network(void) {
    char buf[8192];
    if (!read_line("/proc/net/dev", buf, sizeof buf)) return;
    uint64_t rx = 0, tx = 0;
    for (char *line = buf; line && *line;) {
        char *next = strchr(line, '\n');
        char *colon = strchr(line, ':');
        if (colon) {
            unsigned long long r = 0, t = 0;
            if (sscanf(colon + 1, "%llu %*u %*u %*u %*u %*u %*u %*u %llu", &r, &t) == 2) {
                rx += r;
                tx += t;
            }
        }
        line = next ? next + 1 : NULL;
    }
    g.net_rx = rx;
    g.net_tx = tx;
    g.net_ok = true;
}

static void sample_processes(double elapsed) {
    DIR *dir = opendir("/proc");
    if (!dir) return;
    g.proc_count = 0;
    struct dirent *entry;
    char path[64], buf[1024];
    while ((entry = readdir(dir))) {
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
        uint64_t pid = strtoull(entry->d_name, NULL, 10);
        snprintf(path, sizeof path, "/proc/%llu/stat", (unsigned long long)pid);
        if (!read_line(path, buf, sizeof buf)) continue;
        /* The command name is in parentheses and may contain spaces, so the
         * parse starts after the last ')'. Then: state, ppid, ..., utime=11,
         * stime=12, ..., num_threads=17 (1-based after the name). */
        char *close = strrchr(buf, ')');
        if (!close) continue;
        char *rest = close + 2;
        char state = 0;
        int scanned = 0;
        unsigned long long utime = 0, stime = 0;
        long long threads = 0;
        char *cursor = rest;
        for (int field = 1; field <= 17 && cursor; field++) {
            switch (field) {
            case 1: scanned += sscanf(cursor, "%c", &state); break;
            case 11: scanned += sscanf(cursor, "%llu", &utime); break;
            case 12: scanned += sscanf(cursor, "%llu", &stime); break;
            case 17: scanned += sscanf(cursor, "%lld", &threads); break;
            default: break;
            }
            cursor = strchr(cursor, ' ');
            if (cursor) cursor++;
        }
        if (scanned < 3) continue;

        struct proc_sample s;
        memset(&s, 0, sizeof s);
        s.pid = pid;
        snprintf(path, sizeof path, "/proc/%llu/comm", (unsigned long long)pid);
        if (read_line(path, buf, sizeof buf)) {
            char *nl = strchr(buf, '\n');
            if (nl) *nl = 0;
            copy_name(s.name, sizeof s.name, buf);
        } else {
            copy_name(s.name, sizeof s.name, "?");
        }
        snprintf(path, sizeof path, "/proc/%llu/statm", (unsigned long long)pid);
        if (read_line(path, buf, sizeof buf)) {
            unsigned long long pages = 0, resident = 0;
            if (sscanf(buf, "%llu %llu", &pages, &resident) == 2)
                s.mem = resident * (uint64_t)sysconf(_SC_PAGESIZE);
        }
        s.threads = (int64_t)threads;
        /* 100 ticks a second is the usual USER_HZ, and the exact clock does not
         * change which processes are busy. */
        uint64_t ticks = (utime + stime) * (1000000000ull / 100ull);
        uint64_t before = 0;
        if (elapsed > 0.0 && prev_ticks(pid, &before) && ticks > before)
            s.cpu = (double)(ticks - before) / (elapsed * 1e9);
        note_prev(pid, ticks);
        insert_process(&s);
    }
    closedir(dir);
}

#else

static void sample_cpu(void) {}
static void sample_memory(void) {}
static void sample_load_and_uptime(void) {}
static void sample_network(void) {}
static void sample_processes(double elapsed) { (void)elapsed; }

#endif

/* --- the API ------------------------------------------------------------- */

static double g_prev_time;

bool sys_sample(void) {
#if !defined(__APPLE__) && !defined(__linux__)
    return false;
#else
    double now = monotonic_seconds();
    double elapsed = g_prev_time > 0.0 ? now - g_prev_time : 0.0;
    g_prev_time = now;

    sample_cpu();
    sample_memory();
    sample_load_and_uptime();
    sample_network();
    sample_processes(elapsed);
    g.ready = true;
    return g.ready;
#endif
}

double sys_cpu_usage(void) { return g.cpu; }
uint64_t sys_mem_used(void) { return g.mem_used; }
uint64_t sys_mem_total(void) { return g.mem_total; }
double sys_uptime(void) { return g.uptime; }

double sys_load_average(int64_t index) {
    if (index < 0 || index > 2) return 0.0;
    return g.load[index];
}

bool sys_disk(const uint8_t *path, int64_t path_len, uint64_t *free_bytes,
              uint64_t *total_bytes) {
    char buf[1024];
    int64_t n = path_len < (int64_t)sizeof buf - 1 ? path_len : (int64_t)sizeof buf - 1;
    memcpy(buf, path, (size_t)n);
    buf[n] = 0;
#if defined(__APPLE__) || defined(__linux__)
    struct statvfs vfs;
    if (statvfs(buf, &vfs) != 0) return false;
    store_u64(free_bytes, (uint64_t)vfs.f_bavail * (uint64_t)vfs.f_frsize);
    store_u64(total_bytes, (uint64_t)vfs.f_blocks * (uint64_t)vfs.f_frsize);
    return true;
#else
    (void)free_bytes;
    (void)total_bytes;
    return false;
#endif
}

bool sys_net_bytes(uint64_t *rx, uint64_t *tx) {
    if (!g.net_ok) return false;
    store_u64(rx, g.net_rx);
    store_u64(tx, g.net_tx);
    return true;
}

int64_t sys_process_count(void) { return g.proc_count; }

bool sys_process(int64_t index, uint8_t *name, int64_t name_cap, double *cpu, uint64_t *mem,
                 int64_t *threads) {
    if (index < 0 || index >= g.proc_count) return false;
    const struct proc_sample *s = &g.procs[index];
    int64_t n = name_cap < (int64_t)sizeof s->name ? name_cap : (int64_t)sizeof s->name;
    for (int64_t i = 0; i < n; i++) name[i] = (uint8_t)s->name[i];
    store_f64(cpu, s->cpu);
    store_u64(mem, s->mem);
    store_i64(threads, s->threads);
    return true;
}
