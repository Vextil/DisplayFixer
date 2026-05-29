#import "DisplayFixCore.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <mach/mach_error.h>
#include <unistd.h>

// ---- SkyLight (private) ----
typedef int CGSError;
extern int      SLSDisplaySupportsHDRMode(CGDirectDisplayID);
extern int      SLSDisplayIsHDRModeEnabled(CGDirectDisplayID);
extern CGSError SLSDisplaySetHDRModeEnabled(CGDirectDisplayID, bool);

// IOAVVideoInterface, the DCP's live per-link color data
typedef CFTypeRef IOAVVideoInterfaceRef;
extern IOAVVideoInterfaceRef IOAVVideoInterfaceCreateWithLocation(CFAllocatorRef, uint32_t); // 0 = External
extern CFArrayRef IOAVVideoInterfaceCopyColorElements(IOAVVideoInterfaceRef);
extern int IOAVVideoInterfaceGetLinkData(IOAVVideoInterfaceRef, void *outStruct256); // user-client sel 2: fills a 256-byte live-link struct
extern IOAVVideoInterfaceRef IOAVVideoInterfaceCreateWithService(CFAllocatorRef, io_service_t);

// ---- VMM7100 "reset board" HID packets (waydabber/vmm7100reset; "PRIUS" unlock in P1) ----
static uint8_t P1[62] = {0x01,0x00,0x11,0x00,0x00,0x81,0x00,0x00,0x00,0x00,0x00,0x05,0x00,0x00,0x00,0x50,0x52,0x49,0x55,0x53,0xD6};
static uint8_t P2[62] = {0x01,0x00,0x0C,0x00,0x00,0xB1,0x00,0x2C,0x02,0x20,0x20,0x04,0x00,0x00,0x00,0xD1,0x20,0x00,0x71,[47]=0xB8};
static uint8_t P3[62] = {0x01,0x00,0x10,0x00,0x00,0xA1,0x00,0x1C,0x02,0x20,0x20,0x04,0x00,0x00,0x00,0xF5,0x00,0x00,0x00,0xF8,[47]=0x33};

// ---- logging ----
static NSString *gLogPath = nil;
void DFSetLogPath(NSString *path) { gLogPath = [path copy]; }
void DFLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    fputs(line.UTF8String, stderr);
    if (gLogPath) { FILE *f = fopen(gLogPath.UTF8String, "a"); if (f) { fputs(line.UTF8String, f); fclose(f); } }
}

CGDirectDisplayID DFExternalDisplay(void) {
    uint32_t n = 0; CGGetActiveDisplayList(0, NULL, &n);
    if (!n) return kCGNullDirectDisplay;
    CGDirectDisplayID ids[16]; if (n > 16) n = 16; CGGetActiveDisplayList(n, ids, &n);
    for (uint32_t i = 0; i < n; i++) if (!CGDisplayIsBuiltin(ids[i])) return ids[i];
    return kCGNullDirectDisplay;
}

// Find a *live* External video interface. The DCP can leave stale duplicate "External"
// DCPAVVideoInterfaceProxy nodes (seen after an offline/relink event); a handle made from the wrong
// one returns kIOReturnNoDevice. So pick the node whose GetLinkData actually succeeds; fall back to
// the location-indexed API. Caller releases.
static IOAVVideoInterfaceRef DFCopyLiveExternalVI(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVVideoInterfaceProxy"), &it) == KERN_SUCCESS) {
        io_service_t s; IOAVVideoInterfaceRef live = NULL;
        while ((s = IOIteratorNext(it))) {
            CFTypeRef loc = IORegistryEntrySearchCFProperty(s, kIOServicePlane, CFSTR("Location"), kCFAllocatorDefault, kIORegistryIterateRecursively);
            BOOL ext = (loc && CFGetTypeID(loc) == CFStringGetTypeID() && CFStringCompare(loc, CFSTR("External"), 0) == kCFCompareEqualTo);
            if (loc) CFRelease(loc);
            if (ext && !live) {
                IOAVVideoInterfaceRef vi = IOAVVideoInterfaceCreateWithService(kCFAllocatorDefault, s);
                if (vi) {
                    unsigned char ld[512]; memset(ld, 0, sizeof ld);
                    if (IOAVVideoInterfaceGetLinkData(vi, ld) == 0) live = vi; else CFRelease(vi);
                }
            }
            IOObjectRelease(s);
        }
        IOObjectRelease(it);
        if (live) return live;
    }
    // Fallback: location 0 is External by Apple's convention. Don't scan other locations — those can
    // be the builtin panel, which we must never report on (it would misread as a different resolution).
    IOAVVideoInterfaceRef vi = IOAVVideoInterfaceCreateWithLocation(kCFAllocatorDefault, 0);
    if (vi) { unsigned char ld[512]; memset(ld, 0, sizeof ld); if (IOAVVideoInterfaceGetLinkData(vi, ld) == 0) return vi; CFRelease(vi); }
    return NULL;
}

// Read the live negotiated link state straight from the DCP (user-client selector 2). It fills a
// 256-byte struct; the fields we need sit at fixed offsets (verified on macOS 26): depth (bpc) @0x08,
// width @0x30, height @0x50, refresh @0x62, DSC PPS block @0x80+.
BOOL DFReadActiveLink(int *depthOut, BOOL *dscOut, int *wOut, int *hOut, int *refrOut) {
    IOAVVideoInterfaceRef vi = DFCopyLiveExternalVI();
    if (!vi) return NO;
    unsigned char ld[512]; memset(ld, 0, sizeof ld);
    int r = IOAVVideoInterfaceGetLinkData(vi, ld);
    CFRelease(vi);
    if (r != 0) return NO;
    const uint32_t *u = (const uint32_t *)ld;
    if (depthOut) *depthOut = (int)u[2];
    if (wOut)     *wOut     = (int)u[12];
    if (hOut)     *hOut     = (int)u[20];
    if (refrOut)  *refrOut  = ld[0x62];
    if (dscOut)   { BOOL p = NO; for (int i = 0x80; i < 0x90; i++) if (ld[i]) { p = YES; break; } *dscOut = p; }
    return YES;
}

// Scan the connection color elements for a live-DSC bit (SupportsDSC bit0): in the good state the
// DSC-capable modes read 3 (bit0 set); when DSC drops they read 2/0 (bit0 clear). Returns YES if no
// element reports DSC active. Kept as a corroborating signal / fallback if GetLinkData is unavailable.
static BOOL DFNoDSCActive(void) {
    IOAVVideoInterfaceRef vi = DFCopyLiveExternalVI();
    if (!vi) return NO;  // can't read the link — don't claim degraded
    CFArrayRef elems = IOAVVideoInterfaceCopyColorElements(vi);
    BOOL dscActive = NO;
    if (elems) {
        for (CFIndex i = 0; i < CFArrayGetCount(elems) && !dscActive; i++) {
            CFDictionaryRef e = CFArrayGetValueAtIndex(elems, i);
            if (CFGetTypeID(e) != CFDictionaryGetTypeID()) continue;
            CFNumberRef v = CFDictionaryGetValue(e, CFSTR("SupportsDSC"));
            long s = 0;
            if (v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue(v, kCFNumberLongType, &s) && (s & 1)) dscActive = YES;
        }
        CFRelease(elems);
    }
    CFRelease(vi);
    return !dscActive;
}

// "Degraded" = the wire fell back from 10-bit 4:4:4 (DSC) to ~8-bit 4:2:2. Two connection-level
// signals: the live active bit depth (<10 ⇒ degraded) and the DSC-bit scan. 
// Either flagging degraded counts.
BOOL DFIsDegraded(CGDirectDisplayID d) {
    (void)d;
    int depth = 0;
    BOOL haveLink = DFReadActiveLink(&depth, NULL, NULL, NULL, NULL);
    BOOL dscBitDegraded = DFNoDSCActive();
    if (haveLink && depth > 0) return depth < 10 || dscBitDegraded;
    return dscBitDegraded;
}

NSString *DFStatusLine(void) {
    CGDirectDisplayID d = DFExternalDisplay();
    if (d == kCGNullDirectDisplay) return @"No external display";
    int depth = 0, w = 0, h = 0, refr = 0; BOOL dsc = NO;
    BOOL haveLink = DFReadActiveLink(&depth, &dsc, &w, &h, &refr);
    BOOL degraded = DFIsDegraded(d);
    if (haveLink && depth > 0) {
        NSString *mode = [NSString stringWithFormat:(dsc ? @"%d-bit 4:4:4 (DSC)" : @"%d-bit (no DSC)"), depth];
        if (w > 0 && h > 0)
            return [NSString stringWithFormat:@"External: %@ · %d×%d@%d%@", mode, w, h, refr, degraded ? @" — degraded" : @""];
        return [NSString stringWithFormat:@"External: %@%@", mode, degraded ? @" — degraded" : @""];
    }
    return degraded ? @"External: degraded (needs fix)" : @"External: 10-bit 4:4:4 capable";
}

// Send the 3-packet VMM7100 reset. Interface open fails with exclusive-access on macOS 26,
// so we use device-level DeviceRequest (which works).
static BOOL DFSendVMMReset(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    SInt32 vid = 0x06CB, pid = 0x7100;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &vid), p = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v); CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    CFRelease(v); CFRelease(p);
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) { DFLog(@"reset: matching failed"); return NO; }
    io_service_t devsvc; IOUSBDeviceInterface **dev = NULL;
    while ((devsvc = IOIteratorNext(it))) {
        IOCFPlugInInterface **plug = NULL; SInt32 s = 0;
        if (IOCreatePlugInInterfaceForService(devsvc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &s) == KERN_SUCCESS && plug) {
            (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (void **)&dev);
            (*plug)->Release(plug);
        }
        IOObjectRelease(devsvc); if (dev) break;
    }
    IOObjectRelease(it);
    if (!dev) { DFLog(@"reset: VMM7100 (06CB:7100) not found on USB"); return NO; }

    uint8_t *pk[3] = {P1, P2, P3}; BOOL ok = NO;
    IOReturn od = (*dev)->USBDeviceOpen(dev);
    if (od == kIOReturnSuccess) {
        ok = YES;
        for (int i = 0; i < 3; i++) {
            IOUSBDevRequest r; r.bmRequestType=0x21; r.bRequest=0x09; r.wValue=0x0201; r.wIndex=0; r.wLength=61; r.pData=pk[i]; r.wLenDone=0;
            IOReturn rr = (*dev)->DeviceRequest(dev, &r);
            DFLog(@"reset: packet%d=0x%08x (%s)", i+1, rr, mach_error_string(rr));
            if (rr != kIOReturnSuccess) ok = NO;
            if (i < 2) sleep(1);
        }
        (*dev)->USBDeviceClose(dev);
    } else {
        DFLog(@"reset: USBDeviceOpen failed 0x%08x (%s)", od, mach_error_string(od));
    }
    (*dev)->Release(dev);
    return ok;
}

DFResult DFRunFix(BOOL force, NSString **summaryOut) {
    CGDirectDisplayID d = DFExternalDisplay();
    if (d == kCGNullDirectDisplay) { if (summaryOut) *summaryOut = @"no external display"; DFLog(@"fix: no external display"); return DFResultNoDisplay; }
    BOOL degraded = DFIsDegraded(d);
    DFLog(@"fix: external=0x%x degraded=%d force=%d", d, degraded, force);
    if (!degraded && !force) { if (summaryOut) *summaryOut = @"already capable; skipped"; return DFResultSkipped; }

    DFLog(@"fix: sending VMM7100 reset...");
    if (!DFSendVMMReset()) { if (summaryOut) *summaryOut = @"reset failed"; return DFResultResetFailed; }

    DFLog(@"fix: waiting for link to re-negotiate...");
    CGDirectDisplayID d2 = kCGNullDirectDisplay; int i;
    for (i = 0; i < 40; i++) {   // up to ~20s
        usleep(500000);
        d2 = DFExternalDisplay();
        if (d2 != kCGNullDirectDisplay && SLSDisplaySupportsHDRMode(d2) == 1) break;
    }
    if (d2 == kCGNullDirectDisplay) { if (summaryOut) *summaryOut = @"display did not return"; DFLog(@"fix: display did not return"); return DFResultNoReturn; }
    DFLog(@"fix: link back external=0x%x HDRsupported=%d after %.1fs", d2, SLSDisplaySupportsHDRMode(d2), (i+1)*0.5);

    usleep(2000000); // let the post-reset re-negotiation settle before toggling HDR

    DFLog(@"fix: enabling HDR to force 10-bit/DSC...");
    SLSDisplaySetHDRModeEnabled(d2, true);
    for (int k = 0; k < 10 && !SLSDisplayIsHDRModeEnabled(d2); k++) usleep(300000); // confirm enabled
    usleep(2500000); // CRITICAL: let the HDR reconfigure fully settle before reversing it,
                     // otherwise the disable collides with the in-flight enable and is dropped.

    DFLog(@"fix: disabling HDR -> 10-bit 4:4:4 SDR...");
    BOOL off = NO;
    for (int attempt = 0; attempt < 3 && !off; attempt++) {
        SLSDisplaySetHDRModeEnabled(d2, false);
        for (int k = 0; k < 12; k++) { usleep(300000); if (!SLSDisplayIsHDRModeEnabled(d2)) { off = YES; break; } }
        if (!off) DFLog(@"fix: HDR still on after disable attempt %d; retrying", attempt + 1);
    }
    int fdepth = 0; BOOL fdsc = NO; DFReadActiveLink(&fdepth, &fdsc, NULL, NULL, NULL);
    BOOL stillDegraded = DFIsDegraded(d2);
    DFLog(@"fix: done (HDRon=%d, active=%d-bit dsc=%d, degraded=%d)%@",
          SLSDisplayIsHDRModeEnabled(d2), fdepth, fdsc, stillDegraded,
          off ? @"" : @" — WARNING: HDR did not turn off");
    if (summaryOut) *summaryOut = stillDegraded ? @"reset done, but still degraded" : @"reset + 10-bit 4:4:4 (SDR)";
    return DFResultFixed;
}
