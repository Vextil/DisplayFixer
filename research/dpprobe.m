// dpprobe.m — minimal IOAVService / DP reset probe for Apple Silicon
// Build:  clang -fobjc-arc -fmodules -framework Foundation -framework IOKit -framework CoreDisplay dpprobe.m -o dpprobe
// Run:    ./dpprobe                 (read-only: enumerate + DDC read)
//         ./dpprobe retrain-frl     (selector 9  on External DCPAVServiceProxy)
//         ./dpprobe relink          (StopLink+StartLink on External AV service)
// NO sudo required. Targets the External DCPAVServiceProxy only.
@import Foundation;
@import IOKit;

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef, io_service_t);
extern IOReturn IOAVServiceReadI2C (IOAVServiceRef, uint32_t chip, uint32_t off, void*, uint32_t);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t chip, uint32_t off, void*, uint32_t);
extern IOReturn IOAVServiceStartLink(IOAVServiceRef, uint32_t);
extern IOReturn IOAVServiceStopLink (IOAVServiceRef, uint32_t);
extern IOReturn IOAVServiceRetrainFRL(IOAVServiceRef);
extern IOReturn IOAVServiceCopyEDID(IOAVServiceRef, CFDataRef*);

// Find the External DCPAVServiceProxy and wrap it in an IOAVService.
static IOAVServiceRef copyExternalAVService(io_service_t *outService) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"), &it) != KERN_SUCCESS) return NULL;
    io_service_t svc; IOAVServiceRef av = NULL;
    while ((svc = IOIteratorNext(it))) {
        CFTypeRef loc = IORegistryEntrySearchCFProperty(svc, kIOServicePlane,
            CFSTR("Location"), kCFAllocatorDefault, kIORegistryIterateRecursively);
        BOOL external = (loc && CFGetTypeID(loc)==CFStringGetTypeID()
                         && CFStringCompare(loc, CFSTR("External"), 0)==kCFCompareEqualTo);
        if (loc) CFRelease(loc);
        if (external) {
            av = IOAVServiceCreateWithService(kCFAllocatorDefault, svc);
            if (av) { if (outService) { *outService = svc; } break; }
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return av;
}

int main(int argc, char **argv) { @autoreleasepool {
    io_service_t svc = 0;
    IOAVServiceRef av = copyExternalAVService(&svc);
    if (!av) { fprintf(stderr, "No External DCPAVServiceProxy / IOAVService found.\n"); return 1; }
    fprintf(stderr, "Got External IOAVService %p\n", av);

    // EDID sanity (read-only)
    CFDataRef edid = NULL;
    if (IOAVServiceCopyEDID(av, &edid)==kIOReturnSuccess && edid) {
        fprintf(stderr, "EDID: %ld bytes\n", (long)CFDataGetLength(edid)); CFRelease(edid);
    }
    // DDC read of luminance (VCP 0x10) as a liveness check (selector 24 under the hood)
    uint8_t req[] = { 0x82, 0x01, 0x10, 0x00 };
    req[3] = 0x6e ^ req[0] ^ req[1] ^ req[2];
    (void)IOAVServiceWriteI2C(av, 0x37, 0x51, req, sizeof req);
    usleep(50000);
    uint8_t reply[11] = {0};
    IOReturn r = IOAVServiceReadI2C(av, 0x37, 0, reply, sizeof reply);
    fprintf(stderr, "DDC read ret=0x%x cur=%u max=%u\n", r,
            (reply[8]<<8)|reply[9], (reply[6]<<8)|reply[7]);

    const char *cmd = argc>1 ? argv[1] : "";
    if (!strcmp(cmd,"retrain-frl")) {
        IOReturn rr = IOAVServiceRetrainFRL(av);
        fprintf(stderr, "IOAVServiceRetrainFRL ret=0x%x\n", rr);
    } else if (!strcmp(cmd,"relink")) {
        IOReturn s1 = IOAVServiceStopLink(av, 0);  usleep(200000);
        IOReturn s2 = IOAVServiceStartLink(av, 0);
        fprintf(stderr, "StopLink=0x%x StartLink=0x%x\n", s1, s2);
    } else {
        fprintf(stderr, "(read-only; pass 'retrain-frl' or 'relink' to act)\n");
    }
    CFRelease(av); if (svc) IOObjectRelease(svc);
    return 0;
}}
