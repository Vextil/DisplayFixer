// displayfix.m — DisplayFixer core: reset the VMM7100, wait for re-negotiation, set 10-bit 4:4:4.
// Modes:
//   ./displayfix          fix only if degraded (HDR unsupported == DSC link not established)
//   ./displayfix force     always reset + set, regardless of current state
//   ./displayfix status    read-only: print external display + HDR support/state
//
// Mechanism (validated on M4 Pro / macOS 26.4.1, Samsung 4K@165 via Cable Matters VMM7100):
//   1. USB HID reset to Synaptics VMM7100 (VID 06CB/PID 7100) — re-negotiates the link into a
//      DSC-capable state (SLSDisplaySupportsHDRMode flips 0 -> 1, re-exposing 10-bit 4:4:4).
//      Interface-level open fails with exclusive-access on macOS 26 (this is why BetterDisplay's
//      reset broke); we fall back to device-level DeviceRequest, which works.
//   2. After the link re-detects, toggle HDR on then off (SLSDisplaySetHDRModeEnabled) — lands
//      the wire on 10-bit 4:4:4 SDR.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
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

// ---- logging (stderr + project log file) ----
static void flog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    fputs(line.UTF8String, stderr);
}

static CGDirectDisplayID externalDisplay(void) {
    uint32_t n = 0; CGGetActiveDisplayList(0, NULL, &n);
    if (!n) return kCGNullDirectDisplay;
    CGDirectDisplayID ids[16]; if (n > 16) n = 16; CGGetActiveDisplayList(n, ids, &n);
    for (uint32_t i = 0; i < n; i++) if (!CGDisplayIsBuiltin(ids[i])) return ids[i];
    return kCGNullDirectDisplay;
}

// Send the 3-packet VMM7100 reset. Tries interface open, falls back to device-level.
static bool sendVMMReset(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    SInt32 vid = 0x06CB, pid = 0x7100;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &vid), p = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v); CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    CFRelease(v); CFRelease(p);
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) { flog(@"reset: matching failed"); return false; }
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
    if (!dev) { flog(@"reset: VMM7100 not found on USB"); return false; }

    uint8_t *pk[3] = {P1, P2, P3}; bool ok = false;
    IOReturn od = (*dev)->USBDeviceOpen(dev);
    if (od == kIOReturnSuccess) {
        ok = true;
        for (int i = 0; i < 3; i++) {
            IOUSBDevRequest r; r.bmRequestType=0x21; r.bRequest=0x09; r.wValue=0x0201; r.wIndex=0; r.wLength=61; r.pData=pk[i]; r.wLenDone=0;
            IOReturn rr = (*dev)->DeviceRequest(dev, &r);
            flog(@"reset: packet%d=0x%08x (%s)", i+1, rr, mach_error_string(rr));
            if (rr != kIOReturnSuccess) ok = false;
            if (i < 2) sleep(1);
        }
        (*dev)->USBDeviceClose(dev);
    } else {
        flog(@"reset: USBDeviceOpen failed 0x%08x (%s)", od, mach_error_string(od));
    }
    (*dev)->Release(dev);
    return ok;
}

static bool isDegraded(CGDirectDisplayID d) { return SLSDisplaySupportsHDRMode(d) == 0; }

static int runFix(bool force) {
    CGDirectDisplayID d = externalDisplay();
    if (d == kCGNullDirectDisplay) { flog(@"fix: no external display"); return 1; }
    bool degraded = isDegraded(d);
    flog(@"fix: external=0x%x HDRsupported=%d degraded=%d force=%d", d, !degraded, degraded, force);
    if (!degraded && !force) { flog(@"fix: link already DSC-capable; nothing to do"); return 0; }

    flog(@"fix: sending VMM7100 reset...");
    if (!sendVMMReset()) { flog(@"fix: reset failed"); return 2; }

    flog(@"fix: waiting for link to re-negotiate...");
    CGDirectDisplayID d2 = kCGNullDirectDisplay; int i;
    for (i = 0; i < 40; i++) {            // up to ~20s
        usleep(500000);
        d2 = externalDisplay();
        if (d2 != kCGNullDirectDisplay && SLSDisplaySupportsHDRMode(d2) == 1) break;
    }
    if (d2 == kCGNullDirectDisplay) { flog(@"fix: display did not return after reset"); return 3; }
    flog(@"fix: link back: external=0x%x HDRsupported=%d (after %.1fs)", d2, SLSDisplaySupportsHDRMode(d2), (i+1)*0.5);

    flog(@"fix: setting 10-bit 4:4:4 (HDR on->off)...");
    CGSError e1 = SLSDisplaySetHDRModeEnabled(d2, true);  usleep(1500000);
    CGSError e2 = SLSDisplaySetHDRModeEnabled(d2, false); usleep(1000000);
    flog(@"fix: HDR set on=%d off=%d HDRon(final)=%d — done.", e1, e2, SLSDisplayIsHDRModeEnabled(d2));
    return 0;
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *cmd = (argc > 1) ? @(argv[1]) : @"fix";
    if ([cmd isEqualToString:@"status"]) {
        CGDirectDisplayID d = externalDisplay();
        printf("external=0x%x HDRsupported=%d HDRon=%d degraded=%d\n",
               d, d?SLSDisplaySupportsHDRMode(d):0, d?SLSDisplayIsHDRModeEnabled(d):0, d?isDegraded(d):1);
        return 0;
    }
    return runFix([cmd isEqualToString:@"force"]);
}}
