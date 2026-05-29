// inspect.m — read current mode + enumerate allowed configs for all displays (READ-ONLY)
// Build: clang -fobjc-arc -fmodules -framework Foundation -framework CoreGraphics -framework CoreDisplay inspect.m -o inspect
@import Foundation;
@import CoreGraphics;

// private CoreDisplay: returns a rich info dict for a display (caller releases)
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

static char g_buf[512];
static const char* cs(CFStringRef s){ if(!s) return "(null)"; g_buf[0]=0;
    CFStringGetCString(s, g_buf, sizeof g_buf, kCFStringEncodingUTF8); return g_buf; }

int main(void){ @autoreleasepool {
    CGDirectDisplayID ids[16]; uint32_t n=0;
    CGGetOnlineDisplayList(16, ids, &n);
    for(uint32_t i=0;i<n;i++){
        CGDirectDisplayID d = ids[i];
        int builtin = CGDisplayIsBuiltin(d);
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
        size_t w = CGDisplayModeGetPixelWidth(m), h = CGDisplayModeGetPixelHeight(m);
        double hz = CGDisplayModeGetRefreshRate(m);
        CFStringRef enc = CGDisplayModeCopyPixelEncoding(m);
        fprintf(stderr, "\n=== Display 0x%x  builtin=%d  vendor=0x%x model=0x%x ===\n",
                d, builtin, CGDisplayVendorNumber(d), CGDisplayModelNumber(d));
        fprintf(stderr, "current: %zux%zu @%.2fHz  framebufferEncoding=%s\n", w,h,hz, cs(enc));
        if(enc) CFRelease(enc);
        CGDisplayModeRelease(m);
        if(builtin) continue;

        // All allowed modes (4K+ only, to cut noise) with their framebuffer encodings
        CFDictionaryRef opt = (__bridge CFDictionaryRef)@{
            (__bridge NSString*)kCGDisplayShowDuplicateLowResolutionModes : @YES };
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, opt);
        if(modes){
            fprintf(stderr, "allowed 4K+ modes (%ld total):\n", (long)CFArrayGetCount(modes));
            for(CFIndex k=0;k<CFArrayGetCount(modes);k++){
                CGDisplayModeRef mm = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes,k);
                size_t pw=CGDisplayModeGetPixelWidth(mm), ph=CGDisplayModeGetPixelHeight(mm);
                if(pw<3840) continue;
                CFStringRef en = CGDisplayModeCopyPixelEncoding(mm);
                fprintf(stderr, "  %4zux%-4zu @%6.2f  enc=%s\n", pw,ph,
                        CGDisplayModeGetRefreshRate(mm), cs(en));
                if(en) CFRelease(en);
            }
            CFRelease(modes);
        }

        // CoreDisplay info dict (may carry current depth / HDR / color info)
        CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(d);
        if(info){ fprintf(stderr, "--- CoreDisplay info dict ---\n"); CFShow(info); CFRelease(info); }
    }
    return 0;
}}
