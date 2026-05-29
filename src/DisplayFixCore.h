// DisplayFixCore — the reset + set-10-bit-4:4:4 mechanism, independent of any UI.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(int, DFResult) {
    DFResultFixed       = 0,   // ran the reset + set sequence
    DFResultNoDisplay   = 1,   // no external display found
    DFResultResetFailed = 2,   // USB reset could not be sent
    DFResultNoReturn    = 3,   // display did not come back after reset
    DFResultSkipped     = 4,   // not degraded and not forced — nothing to do
};

/// First non-builtin display, or kCGNullDirectDisplay.
CGDirectDisplayID DFExternalDisplay(void);

/// YES when the wire has fallen back from 10-bit 4:4:4 (DSC) to ~8-bit 4:2:2.
BOOL DFIsDegraded(CGDirectDisplayID d);

/// Read the live negotiated link state off the DCP (the exact wire format). Returns NO if unavailable.
/// Any out-param may be NULL. depth = active bits-per-component; dsc = DSC/4:4:4 active.
BOOL DFReadActiveLink(int *depthOut, BOOL *dscOut, int *wOut, int *hOut, int *refrOut);

/// Human-readable one-liner for the menu/tooltip.
NSString *DFStatusLine(void);

/// Run the fix synchronously. CALL OFF THE MAIN THREAD (it sleeps for seconds).
/// force=NO  → only acts if degraded.  force=YES → always reset + set.
/// summaryOut (optional) gets a short result description.
DFResult DFRunFix(BOOL force, NSString **summaryOut);

/// Set where DFLog appends. Defaults to stderr only until called.
void DFSetLogPath(NSString *path);
void DFLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
