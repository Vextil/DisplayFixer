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

BOOL DFIsDegraded(CGDirectDisplayID d) { return d != kCGNullDirectDisplay && SLSDisplaySupportsHDRMode(d) == 0; }

NSString *DFStatusLine(void) {
    CGDirectDisplayID d = DFExternalDisplay();
    if (d == kCGNullDirectDisplay) return @"No external display";
    return DFIsDegraded(d) ? @"External: degraded (needs fix)"
                           : @"External: 10-bit 4:4:4 capable";
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
    DFLog(@"fix: done (HDRon=%d)%@", SLSDisplayIsHDRModeEnabled(d2), off ? @"" : @" — WARNING: HDR did not turn off");
    if (summaryOut) *summaryOut = off ? @"reset + 10-bit 4:4:4 (SDR)" : @"reset done, but HDR stuck on";
    return DFResultFixed;
}
