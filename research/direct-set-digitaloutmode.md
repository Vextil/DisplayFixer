# Direct set via `IOMobileFramebufferSetDigitalOutMode` (shelved — kept for reference)

A way to set the external display's **connection colour mode directly** (e.g. force 10‑bit RGB 4:4:4)
without the HDR on/off toggle. It works, but it was removed from the app because it can panic the
machine if misused, while the HDR toggle achieves the identical result with zero panic risk. This
documents the mechanism and the exact code that was integrated, so it can be re‑added later.

## Mechanism

The DCP framebuffer exposes the active connection colour mode as a per‑display **"digital out mode"**
ID via the private `IOMobileFramebuffer` framework (link `-framework IOMobileFramebuffer`).

```c
typedef struct __IOMFB *IOMobileFramebufferRef;
extern kern_return_t IOMobileFramebufferOpen(io_service_t, task_port_t, uint32_t type, IOMobileFramebufferRef *);
extern kern_return_t IOMobileFramebufferGetDigitalOutMode(IOMobileFramebufferRef, uint32_t *a, uint32_t *b);
extern kern_return_t IOMobileFramebufferSetDigitalOutMode(IOMobileFramebufferRef, uint32_t a, uint32_t b);
```

- Open the **external** framebuffer: `IOServiceMatching("IOMobileFramebufferShim")`, pick the node with
  `external == YES` whose `DisplayAttributes.ProductAttributes.ProductID == CGDisplayModelNumber(extDisplay)`
  (never the builtin). Then `IOMobileFramebufferOpen(svc, mach_task_self(), 0, &fb)`.
- `GetDigitalOutMode(fb, &a, &b)` → `a` is the active connection‑mode ID, `b` a constant base.
- `SetDigitalOutMode(fb, a, b)` applies the mode `a` (with the same `b`). Async — the wire transitions
  over a few seconds; reads *during* the transition return errors.

On the test Samsung 4K@165 (`b = 10199` throughout):

| `a`     | wire format          |
|---------|----------------------|
| `10208` | 8‑bit YCbCr 4:2:2    |
| `10212` | 10‑bit RGB 4:4:4     |
| `10219` | 10‑bit YCbCr 4:4:4   |

## Major caveats

1. **The mode ID is per‑display, not universal.** `10212` is just where 10‑bit RGB lands in this
   Samsung's mode list. Another monitor -> different ID. There is no safe universal constant. The app
   would have to learn/cache it from a verified‑good state (only when `!DFIsDegraded`, else you'd
   cache the degraded ID).
2. **Calling `SetDigitalOutMode` when the target mode is NOT available PANICS the machine.** In the
   real post‑wake degraded state, only the 8‑bit mode is offered (10‑bit isn't in the list until the
   adapter is re‑negotiated), and applying `10212` there kernel‑panicked. So callers MUST gate on
   availability first. `SLSDisplaySupportsHDRMode(d) == 1` is a reliable "10‑bit is available now"
   signal (it's `0` while degraded).
3. **The VMM reset is still required first.** The reset re‑populates the mode list (makes 10‑bit
   available); only then can the mode be set. So the sequence is: reset -> wait for
   `SLSDisplaySupportsHDRMode==1` -> `SetDigitalOutMode`.
4. **Right after the reset the framebuffer rejects the set for a few seconds** even though 10‑bit is
   already available (`SupportsHDRMode==1`). It returns an error (cleanly, no panic) until ready, so
   retry with backoff, re‑checking availability each attempt.
5. The mode ID stayed stable across a wake/reset in testing (the `CGDirectDisplayID` changed 0x3→0x2
   but `10212` remained 10‑bit RGB). Don't rely on that universally.

## Verdict

Functionally it works (reset -> gate -> retry `SetDigitalOutMode(10212)` -> 10‑bit RGB). But for an
always‑on auto‑fix, a wrong/early call panics the machine, and the HDR toggle lands the identical
10‑bit RGB 4:4:4 with no panic risk. Not worth the risk! `research/digitaloutmode.m` is a standalone 
read/set probe.

---

## Exact code that was integrated

### `DisplayFixCore.m` — externs (top), helpers, config

```objc
#include <mach/mach.h>   // for mach_task_self()

typedef struct __IOMFB *IOMobileFramebufferRef;
extern kern_return_t IOMobileFramebufferOpen(io_service_t, task_port_t, uint32_t, IOMobileFramebufferRef *);
extern kern_return_t IOMobileFramebufferGetDigitalOutMode(IOMobileFramebufferRef, uint32_t *outA, uint32_t *outB);
extern kern_return_t IOMobileFramebufferSetDigitalOutMode(IOMobileFramebufferRef, uint32_t a, uint32_t b);

// Open the *external* framebuffer (never the builtin). Match by ProductID == external CGDisplay model.
static io_service_t DFCopyExternalFBService(void) {
    CGDirectDisplayID d = DFExternalDisplay();
    uint32_t want = (d != kCGNullDirectDisplay) ? CGDisplayModelNumber(d) : 0;
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &it) != KERN_SUCCESS) return 0;
    io_service_t s, match = 0, anyExt = 0;
    while ((s = IOIteratorNext(it))) {
        CFTypeRef ext = IORegistryEntryCreateCFProperty(s, CFSTR("external"), kCFAllocatorDefault, 0);
        BOOL isExt = (ext && CFGetTypeID(ext) == CFBooleanGetTypeID() && CFBooleanGetValue(ext));
        if (ext) CFRelease(ext);
        if (isExt) {
            long pid = -1;
            CFTypeRef da = IORegistryEntryCreateCFProperty(s, CFSTR("DisplayAttributes"), kCFAllocatorDefault, 0);
            if (da && CFGetTypeID(da) == CFDictionaryGetTypeID()) {
                CFDictionaryRef pa = CFDictionaryGetValue((CFDictionaryRef)da, CFSTR("ProductAttributes"));
                if (pa) { CFNumberRef n = CFDictionaryGetValue(pa, CFSTR("ProductID")); if (n) CFNumberGetValue(n, kCFNumberLongType, &pid); }
            }
            if (da) CFRelease(da);
            if (want != 0 && pid == (long)want && !match) { match = s; IOObjectRetain(match); }
            else if (!anyExt) { anyExt = s; IOObjectRetain(anyExt); }
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    if (match) { if (anyExt) IOObjectRelease(anyExt); return match; }
    return anyExt;
}

BOOL DFReadDigitalOutMode(uint32_t *aOut, uint32_t *bOut) {
    io_service_t svc = DFCopyExternalFBService();
    if (!svc) return NO;
    IOMobileFramebufferRef fb = NULL; BOOL ok = NO;
    if (IOMobileFramebufferOpen(svc, mach_task_self(), 0, &fb) == KERN_SUCCESS && fb) {
        uint32_t a = 0, b = 0;
        if (IOMobileFramebufferGetDigitalOutMode(fb, &a, &b) == KERN_SUCCESS && a != 0) {
            if (aOut) *aOut = a; if (bOut) *bOut = b; ok = YES;
        }
    }
    IOObjectRelease(svc);
    return ok;
}

static BOOL DFApplyDigitalOutMode(uint32_t a, uint32_t b) {   // DANGER: only when mode is available
    io_service_t svc = DFCopyExternalFBService();
    if (!svc) return NO;
    IOMobileFramebufferRef fb = NULL; BOOL ok = NO;
    if (IOMobileFramebufferOpen(svc, mach_task_self(), 0, &fb) == KERN_SUCCESS && fb)
        ok = (IOMobileFramebufferSetDigitalOutMode(fb, a, b) == KERN_SUCCESS);
    IOObjectRelease(svc);
    return ok;
}

static BOOL gDirectSetEnabled = NO;
static uint32_t gPrefDigitalA = 0, gPrefDigitalB = 0;
void DFConfigureDirectSet(BOOL enabled, uint32_t a, uint32_t b) { gDirectSetEnabled = enabled; gPrefDigitalA = a; gPrefDigitalB = b; }
```

### `DisplayFixCore.m` — the `DFRunFix` branch (replaces the HDR-only block, after the `SupportsHDRMode==1` gate + 2s settle)

```objc
    BOOL off = YES;        // only meaningful on the HDR path
    BOOL didDirect = NO;
    if (gDirectSetEnabled && gPrefDigitalA != 0) {
        DFLog(@"fix: direct set — SetDigitalOutMode(%u, %u), waiting for the framebuffer to accept it...", gPrefDigitalA, gPrefDigitalB);
        // Post-reset the framebuffer rejects the set for a few seconds even though 10-bit is available
        // — retry with backoff. Re-check availability each attempt (never apply when unavailable: panic).
        for (int attempt = 0; attempt < 8 && !didDirect; attempt++) {
            if (SLSDisplaySupportsHDRMode(d2) == 1 && DFApplyDigitalOutMode(gPrefDigitalA, gPrefDigitalB)) {
                int dd = 0;
                for (int k = 0; k < 12; k++) { usleep(500000); if (DFReadActiveLink(&dd, NULL, NULL, NULL, NULL) && dd >= 10) break; }
                if (dd >= 10) { didDirect = YES; DFLog(@"fix: direct set OK (%d-bit) after %d attempt(s)", dd, attempt + 1); break; }
            }
            usleep(1500000);
        }
        if (!didDirect) DFLog(@"fix: direct set didn't take after retries — falling back to HDR toggle");
    }
    if (!didDirect) {
        // ...the normal HDR on/off block...
    }
```

### `DisplayFixCore.h`

```objc
BOOL DFReadDigitalOutMode(uint32_t *aOut, uint32_t *bOut);
void DFConfigureDirectSet(BOOL enabled, uint32_t a, uint32_t b);
```

### `AppDelegate.m` — toggle + learn/cache

```objc
static NSString *const kUseDirectSetKey  = @"useDirectSet";       // default NO
static NSString *const kCachedModeAKey   = @"cachedDigitalModeA";
static NSString *const kCachedModeBKey   = @"cachedDigitalModeB";
// registerDefaults: add kUseDirectSetKey: @NO

- (void)applyDirectSetConfig {   // call at launch + on toggle
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    DFConfigureDirectSet([ud boolForKey:kUseDirectSetKey],
                         (uint32_t)[ud integerForKey:kCachedModeAKey],
                         (uint32_t)[ud integerForKey:kCachedModeBKey]);
}

- (void)learnGoodModeIfPossible {   // call at launch + after each fix
    CGDirectDisplayID d = DFExternalDisplay();
    if (d == kCGNullDirectDisplay || DFIsDegraded(d)) return;   // never cache the degraded mode
    uint32_t a = 0, b = 0;
    if (!DFReadDigitalOutMode(&a, &b) || a == 0) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ((uint32_t)[ud integerForKey:kCachedModeAKey] != a || (uint32_t)[ud integerForKey:kCachedModeBKey] != b) {
        [ud setInteger:a forKey:kCachedModeAKey];
        [ud setInteger:b forKey:kCachedModeBKey];
    }
    [self applyDirectSetConfig];
}

- (void)toggleDirectSet:(id)sender {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:![ud boolForKey:kUseDirectSetKey] forKey:kUseDirectSetKey];
    [self applyDirectSetConfig];
    [self rebuildMenu];
}
// Menu item: "Set 10-bit directly (experimental — default uses HDR toggle)" -> toggleDirectSet:
```

### `build.sh`

Add `-framework IOMobileFramebuffer` to the clang link line.
