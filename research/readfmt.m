// readfmt.m — READ-ONLY probe: report the External display's current negotiated
// output format (chroma / bits-per-component / range) on Apple Silicon.
//
// This file performs NO mutating operations. Safe to run while a display is in use.
//
// Build:
//   clang -fobjc-arc -fmodules \
//     -F"$(xcrun --sdk macosx --show-sdk-path)/System/Library/PrivateFrameworks" \
//     -framework Foundation -framework IOKit -framework CoreGraphics \
//     -framework CoreDisplay -framework SkyLight \
//     readfmt.m -o readfmt
//
// Run:
//   ./readfmt            # dumps every candidate source for the External display
//
// It cross-references FOUR sources so we can pick the most reliable one empirically:
//   (A) IOAVVideoInterface color/timing elements   (IOKit, the actual link state)
//   (B) CGS current display mode + per-mode pixel-encoding string + depth (SkyLight)
//   (C) The 212-byte CGSDisplayModeDescription for the current mode (hex + decoded ints)
//   (D) CoreDisplay info dictionary / HDR + headroom state
//
// All symbols are private; declared extern below.

@import Foundation;
@import IOKit;
@import CoreGraphics;

// ---- CoreGraphics / CGDisplay public-ish ----
extern CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID, CFDictionaryRef);

// ---- SkyLight (re-exported as CGS* by CoreGraphics) ----
typedef int CGSError;
extern CGSError SLSGetDisplayDepth(CGDirectDisplayID, int *outDepth);
extern CGSError SLSGetDisplayPixelEncodingOfLength(CGDirectDisplayID, char *buf, unsigned long len);
extern CGSError SLSGetDisplayPixelFormat(CGDirectDisplayID, void *);            // shape unknown; probe size
extern CGSError SLSGetCurrentDisplayMode(CGDirectDisplayID, int *modeNum);
extern CGSError SLSGetNumberOfDisplayModes(CGDirectDisplayID, int *count);
extern CGSError SLSGetDisplayModeDescriptionOfLength(CGDirectDisplayID, int idx, void *desc, int len);
// NOTE: SLSCopyDisplayModePixelEncoding takes a CGSDisplayMode *object pointer*
// (it does `ldr x0,[x0,#0x10]` then looks up @"PixelEncoding"), NOT (displayID,idx).
// We do not have a mode-object handle here, so we omit it. Verified via lldb crash.
extern CGSError SLSDisplaySupportsHDRMode(CGDirectDisplayID);
extern CGSError SLSDisplayIsHDRModeEnabled(CGDirectDisplayID);
extern CGSError SLSIsHDREnabled(CGDirectDisplayID);
extern double   SLSGetDisplayMaximumHDRValue(CGDirectDisplayID);

// ---- CoreDisplay ----
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID);
// VERIFIED via disassembly: these three are thin trampolines that dlsym the matching
// SLSDisplay* symbol and tail-call it with (displayID, ...) unchanged — SAFE with a
// CGDirectDisplayID. (CoreDisplay_Display_IsHDR10 / _GetReferenceHeadroom take a C++
// CoreDisplay::Display* object instead and crash on a display id — so we do NOT use them.)
extern bool   CoreDisplay_Display_IsHDRModeEnabled(CGDirectDisplayID);
extern bool   CoreDisplay_Display_SupportsHDRMode(CGDirectDisplayID);

// ---- IOKit IOAV (private) ----
typedef CFTypeRef IOAVServiceRef;
typedef CFTypeRef IOAVVideoInterfaceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef, io_service_t);
extern IOReturn IOAVServiceCopyEDID(IOAVServiceRef, CFDataRef *);
extern IOReturn IOAVServiceCopyProperty(IOAVServiceRef, CFStringRef, CFTypeRef *);

extern IOAVVideoInterfaceRef IOAVVideoInterfaceCreateWithService(CFAllocatorRef, io_service_t);
extern CFArrayRef IOAVVideoInterfaceCopyColorElements(IOAVVideoInterfaceRef);
extern CFArrayRef IOAVVideoInterfaceCopyTimingElements(IOAVVideoInterfaceRef);
extern CFDictionaryRef IOAVVideoInterfaceCopyDisplayAttributes(IOAVVideoInterfaceRef);
extern CFTypeRef IOAVVideoInterfaceCopyProperty(IOAVVideoInterfaceRef, CFStringRef);
extern CFStringRef IOAVVideoInterfaceGetLocation(IOAVVideoInterfaceRef);

// Decoders for the color element data (return human strings / numbers)
extern CFStringRef IOAVVideoPixelEncodingString(uint32_t);
extern CFStringRef IOAVVideoColorSpaceString(uint32_t);
extern CFStringRef IOAVVideoColorDynamicRangeString(uint32_t);
extern uint32_t    IOAVVideoColorBitDepth(uint32_t);

// ---------------------------------------------------------------------------

static CGDirectDisplayID firstExternalCGDisplay(void) {
    uint32_t n = 0; CGGetActiveDisplayList(0, NULL, &n);
    if (!n) return kCGNullDirectDisplay;
    CGDirectDisplayID ids[16]; if (n > 16) n = 16;
    CGGetActiveDisplayList(n, ids, &n);
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayIsBuiltin(ids[i])) continue;
        return ids[i];                       // first non-builtin
    }
    return (n ? ids[0] : kCGNullDirectDisplay);
}

// Find External IOAV* service nodes (DCPAVServiceProxy with Location=="External").
static io_service_t copyExternalAVNode(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"), &it) != KERN_SUCCESS) return 0;
    io_service_t svc, found = 0;
    while ((svc = IOIteratorNext(it))) {
        CFTypeRef loc = IORegistryEntrySearchCFProperty(svc, kIOServicePlane,
            CFSTR("Location"), kCFAllocatorDefault, kIORegistryIterateRecursively);
        BOOL ext = (loc && CFGetTypeID(loc)==CFStringGetTypeID()
                    && CFStringCompare(loc, CFSTR("External"), 0)==kCFCompareEqualTo);
        if (loc) CFRelease(loc);
        if (ext) { found = svc; break; }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found;
}

static void dumpCF(const char *label, CFTypeRef v) {
    if (!v) { printf("  %s = (null)\n", label); return; }
    CFStringRef s = CFCopyDescription(v);
    char buf[4096]; CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    printf("  %s = %s\n", label, buf);
    CFRelease(s);
}

int main(void) { @autoreleasepool {
    CGDirectDisplayID d = firstExternalCGDisplay();
    printf("== External CGDirectDisplayID = 0x%08x ==\n\n", d);

    // ---------- (B) SkyLight current mode / depth / encoding ----------
    printf("---- (B) SkyLight current state ----\n");
    int depth = -1; CGSError e1 = SLSGetDisplayDepth(d, &depth);
    printf("  SLSGetDisplayDepth -> err=%d depth=%d\n", e1, depth);

    char enc[256] = {0};
    CGSError e2 = SLSGetDisplayPixelEncodingOfLength(d, enc, sizeof enc);
    printf("  SLSGetDisplayPixelEncodingOfLength -> err=%d enc=\"%s\"\n", e2, enc);

    int cur = -1, cnt = -1;
    SLSGetCurrentDisplayMode(d, &cur);
    SLSGetNumberOfDisplayModes(d, &cnt);
    printf("  current mode idx=%d  total modes=%d\n", cur, cnt);

    // (SLSCopyDisplayModePixelEncoding needs a CGSDisplayMode object ptr — omitted, see note.)

    // ---------- (C) decode CGSDisplayModeDescription for the current mode ----------
    // EMPIRICAL LAYOUT (verified on M4 Pro / macOS 26.4.1, 212-byte struct):
    //   u32[0]=mode  u32[1]=flags  u32[2]=width  u32[3]=height
    //   u32[4]=depthClass(legacy; NOT bpc)  u32[6]=bitsPerPixel  u32[7]=bitsPerComponent
    //   u32[8]=pixelEncoding enum  u32[9]=refreshHz
    //   bytes[48..] = ASCII channel map, e.g. "--RRRRRRRRRRGGGGGGGGGGBBBBBBBBBB"
    //                 (count of R/G/B  -> RGB n-bit; presence of Y/C/b -> YCbCr; etc.)
    printf("\n---- (C) CGSDisplayModeDescription decode ----\n");
    decodeModeDesc(d, cur, /*verbose=*/1);

    // Scan ALL modes to catalogue the DISTINCT color formats currently offered for the
    // active resolution+refresh. This is exactly the "compatible connection mode list".
    printf("\n  -- distinct color formats offered at %ux%u@~%uHz --\n",
           curW, curH, curHz);
    char seen[64][48]; int nseen = 0;
    for (int i = 0; i < cnt; i++) {
        uint8_t desc[256]; memset(desc, 0, sizeof desc);
        if (SLSGetDisplayModeDescriptionOfLength(d, i, desc, 212) != 0) continue;
        const uint32_t *u = (const uint32_t *)desc;
        if (u[2] != curW || u[3] != curH) continue;          // same resolution
        if (curHz && u[9] && (u[9] < curHz-1 || u[9] > curHz+1)) continue; // ~same Hz
        char enc2[48] = {0}; memcpy(enc2, desc + 48, 32);
        int dup = 0; for (int k=0;k<nseen;k++) if (!strcmp(seen[k], enc2)) { dup=1; break; }
        if (dup) continue;
        if (nseen < 64) strncpy(seen[nseen++], enc2, 47);
        printf("    mode[%3d] bpp=%2u bpc=%2u encEnum=%u Hz=%u  channels=\"%s\"  -> %s\n",
               i, u[6], u[7], u[8], u[9], enc2, summarizeChannels(enc2));
    }

    // ---------- (A) IOAV video interface color/timing elements ----------
    printf("\n---- (A) IOAVVideoInterface color/timing (the real link state) ----\n");
    io_iterator_t it = 0;
    // VideoInterface lives under a DCPAVDeviceProxy / IOMobileFramebuffer node; try matching
    // common class names, falling back to walking the AV service's parents.
    const char *classes[] = { "AppleCLCD2", "IOMobileFramebufferAV",
                              "DCPAVVideoInterface", "AppleDCPAVVideoInterface", NULL };
    io_service_t avnode = copyExternalAVNode();
    printf("  External DCPAVServiceProxy node = 0x%x\n", avnode);
    if (avnode) {
        IOAVVideoInterfaceRef vi = IOAVVideoInterfaceCreateWithService(kCFAllocatorDefault, avnode);
        printf("  IOAVVideoInterfaceCreateWithService(AVnode) = %p\n", (void*)vi);
        if (vi) {
            CFArrayRef ce = IOAVVideoInterfaceCopyColorElements(vi);
            dumpCF("ColorElements", ce); if (ce) CFRelease(ce);
            CFArrayRef te = IOAVVideoInterfaceCopyTimingElements(vi);
            dumpCF("TimingElements", te); if (te) CFRelease(te);
            CFDictionaryRef da = IOAVVideoInterfaceCopyDisplayAttributes(vi);
            dumpCF("DisplayAttributes", da); if (da) CFRelease(da);
            CFRelease(vi);
        }
    }
    // Also enumerate any DCPAVVideoInterface-ish services directly.
    for (int c = 0; classes[c]; c++) {
        io_iterator_t jt = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(classes[c]), &jt) != KERN_SUCCESS)
            continue;
        io_service_t s;
        while ((s = IOIteratorNext(jt))) {
            IOAVVideoInterfaceRef vi = IOAVVideoInterfaceCreateWithService(kCFAllocatorDefault, s);
            if (vi) {
                CFStringRef loc = IOAVVideoInterfaceGetLocation(vi);
                char lb[64] = {0}; if (loc) CFStringGetCString(loc, lb, sizeof lb, kCFStringEncodingUTF8);
                printf("  [class %s] VI loc=%s\n", classes[c], lb);
                CFArrayRef ce = IOAVVideoInterfaceCopyColorElements(vi);
                if (ce) { dumpCF("    ColorElements", ce); CFRelease(ce); }
                CFRelease(vi);
            }
            IOObjectRelease(s);
        }
        IOObjectRelease(jt);
    }
    if (avnode) IOObjectRelease(avnode);

    // ---------- (D) CoreDisplay info dict + HDR ----------
    printf("\n---- (D) CoreDisplay ----\n");
    CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(d);
    dumpCF("InfoDictionary", info); if (info) CFRelease(info);
    printf("  IsHDRModeEnabled=%d SupportsHDRMode=%d IsHDR10=%d refHeadroom=%.3f\n",
           CoreDisplay_Display_IsHDRModeEnabled(d), CoreDisplay_Display_SupportsHDRMode(d),
           CoreDisplay_Display_IsHDR10(d), CoreDisplay_Display_GetReferenceHeadroom(d));
    printf("  SLSDisplaySupportsHDRMode=%d SLSDisplayIsHDRModeEnabled=%d SLSIsHDREnabled=%d maxHDR=%.3f\n",
           SLSDisplaySupportsHDRMode(d), SLSDisplayIsHDRModeEnabled(d),
           SLSIsHDREnabled(d), SLSGetDisplayMaximumHDRValue(d));

    return 0;
}}
