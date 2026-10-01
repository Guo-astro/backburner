// gpu-pstate: sample the M-series GPU clock-state residency and GPU power once per interval, no sudo (IOReport, like macmon).
//   xcrun clang -O2 -o tools/gpu-pstate/gpu-pstate tools/gpu-pstate/gpu-pstate.c -framework CoreFoundation -framework IOKit -lIOReport
//   tools/gpu-pstate/gpu-pstate [interval_ms=1000] [count=0 (forever)]
// Per line: unix time, GPU active % (non-OFF residency), average MHz while active, % of active time at the top state, GPU W,
// plus the residency histogram of the active states. Frequencies come from pmgr voltage-states9 (16 states on the M4 Pro).
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct IOReportSubscriptionRef * IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int);

static double freqs[32];
static int n_freqs = 0;

static void load_freqs(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &it) != KERN_SUCCESS) return;
    io_object_t e;
    while ((e = IOIteratorNext(it))) {
        CFDataRef d = IORegistryEntryCreateCFProperty(e, CFSTR("voltage-states9"), kCFAllocatorDefault, 0);
        if (d) {
            const uint32_t * v = (const uint32_t *) CFDataGetBytePtr(d);
            int n = (int) (CFDataGetLength(d) / 8);
            for (int i = 0; i < n && i < 32; i++) freqs[i] = v[2 * i] / 1e6;
            n_freqs = n < 32 ? n : 32;
            CFRelease(d);
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
}

static int streq(CFStringRef s, const char * c) {
    char buf[128];
    return s && CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8) && strcmp(buf, c) == 0;
}

int main(int argc, char ** argv) {
    int interval = argc > 1 ? atoi(argv[1]) : 1000;
    long count = argc > 2 ? atol(argv[2]) : 0;
    load_freqs();

    CFDictionaryRef gpu = IOReportCopyChannelsInGroup(CFSTR("GPU Stats"), CFSTR("GPU Performance States"), 0, 0, 0);
    CFDictionaryRef en = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    CFMutableDictionaryRef ch = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, gpu);
    if (en) IOReportMergeChannels(ch, en, NULL);
    CFMutableDictionaryRef sub_ch = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, ch, &sub_ch, 0, NULL);
    if (!sub) { fprintf(stderr, "IOReport subscription failed\n"); return 1; }

    CFDictionaryRef prev = IOReportCreateSamples(sub, sub_ch, NULL);
    for (long k = 0; count == 0 || k < count; k++) {
        usleep(interval * 1000);
        CFDictionaryRef cur = IOReportCreateSamples(sub, sub_ch, NULL);
        CFDictionaryRef delta = IOReportCreateSamplesDelta(prev, cur, NULL);
        CFRelease(prev);
        prev = cur;

        CFArrayRef arr = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
        double res[32] = {0}, off = 0, gpu_mj = 0;
        int ns = 0;
        for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); i++) {
            CFDictionaryRef c = CFArrayGetValueAtIndex(arr, i);
            CFStringRef grp = IOReportChannelGetGroup(c), name = IOReportChannelGetChannelName(c);
            if (streq(grp, "GPU Stats") && streq(name, "GPUPH")) {
                ns = IOReportStateGetCount(c);
                for (int s = 0; s < ns && s < 32; s++) {
                    double r = (double) IOReportStateGetResidency(c, s);
                    if (streq(IOReportStateGetNameForIndex(c, s), "OFF") || streq(IOReportStateGetNameForIndex(c, s), "IDLE") || streq(IOReportStateGetNameForIndex(c, s), "DOWN")) off += r;
                    else res[s] = r;
                }
            } else if (streq(grp, "Energy Model") && streq(name, "GPU Energy")) {
                int64_t v = IOReportSimpleGetIntegerValue(c, 0);
                CFStringRef u = IOReportChannelGetUnitLabel(c);
                gpu_mj += streq(u, "nJ") ? v / 1e6 : streq(u, "uJ") ? v / 1e3 : (double) v;
            }
        }
        double act = 0, fsum = 0, top = 0;
        int last = 0;
        for (int s = 0; s < ns && s < 32; s++) if (res[s] > 0) last = s;
        for (int s = 0; s < ns && s < 32; s++) {
            act += res[s];
            // the GPUPH states after OFF map onto voltage-states9[1..]
            double f = (s < n_freqs) ? freqs[s] : 0;
            fsum += res[s] * f;
        }
        top = ns > 0 ? res[ns - 1] : 0;
        double tot = act + off;
        printf("%ld %5.1f%% %6.0f MHz top %5.1f%% %5.2f W |", (long) time(NULL), tot > 0 ? 100 * act / tot : 0,
               act > 0 ? fsum / act : 0, act > 0 ? 100 * top / act : 0, gpu_mj / interval);
        for (int s = 1; s < ns && s < 32; s++) printf(" %.0f", act > 0 ? 100 * res[s] / act : 0);
        printf("\n");
        fflush(stdout);
        (void) last;
        CFRelease(delta);
    }
    return 0;
}
