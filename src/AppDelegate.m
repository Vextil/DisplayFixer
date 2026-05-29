#import "AppDelegate.h"
#import "DisplayFixCore.h"
#import <ServiceManagement/ServiceManagement.h>

static NSString *const kRunOnWakeKey     = @"runOnWake";
static NSString *const kForceEveryWakeKey = @"forceEveryWake";

static const NSTimeInterval kFixCooldown = 30.0;

static const CGFloat kIconHeightBoost = 1.0;
static NSImage *DFMenuBarImage(NSImage *symbol) {
    if (!symbol) return symbol;
    CGFloat h = NSStatusBar.systemStatusBar.thickness;
    NSSize s = symbol.size;
    CGFloat scale = (s.height + kIconHeightBoost) / s.height;
    CGFloat dw = s.width * scale, dh = s.height * scale;
    NSImage *out = [NSImage imageWithSize:NSMakeSize(dw, h) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [symbol drawInRect:NSMakeRect(0, floor((h - dh) / 2.0), dw, dh)
                  fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
        return YES;
    }];
    out.template = YES;
    return out;
}

@implementation AppDelegate {
    NSStatusItem *_item;
    dispatch_queue_t _q;
    BOOL _fixing;
    NSTimeInterval _lastFixEnd;

static AppDelegate *gSelf;

// CGDisplay reconfiguration callback — fires on connect/mode change. Event-driven, not polling.
static void DFReconfigCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *ctx) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kRunOnWakeKey]) return;
    // Ignore our own begin/end-of-reconfigure churn; act on add/enable.
    if (flags & (kCGDisplayAddFlag | kCGDisplayEnabledFlag)) {
        [gSelf scheduleFixAfter:2.5 force:NO reason:@"display connected"];
    }
}

#pragma mark - lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    gSelf = self;
    _q = dispatch_queue_create("com.vextil.displayfixer.fix", DISPATCH_QUEUE_SERIAL);

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud registerDefaults:@{ kRunOnWakeKey: @YES, kForceEveryWakeKey: @NO }];

    NSString *logFile = [self logFilePath];
    [[NSFileManager defaultManager] createDirectoryAtPath:logFile.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    DFSetLogPath(logFile);
    DFLog(@"app: launched");

    _item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [self rebuildMenu];
    [self refreshStatus];

    [[NSWorkspace sharedWorkspace].notificationCenter addObserver:self
        selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    CGDisplayRegisterReconfigurationCallback(DFReconfigCallback, NULL);
}

- (void)didWake:(NSNotification *)n {
    DFLog(@"app: wake detected");
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kRunOnWakeKey]) {
        BOOL force = [[NSUserDefaults standardUserDefaults] boolForKey:kForceEveryWakeKey];
        [self scheduleFixAfter:3.0 force:force reason:@"wake"];
    }
}

#pragma mark - fix scheduling

- (void)scheduleFixAfter:(double)delay force:(BOOL)force reason:(NSString *)reason {
    BOOL manual = [reason isEqualToString:@"manual"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _q, ^{
        if (self->_fixing) { DFLog(@"fix: already running, skipping (%@)", reason); return; }
        // Debounce auto-triggers: skip if a fix just ran (breaks the reset->reconnect->reset loop).
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (!manual && self->_lastFixEnd > 0 && now - self->_lastFixEnd < kFixCooldown) {
            DFLog(@"fix: skipping %@ — within %.0fs cooldown after last fix", reason, kFixCooldown);
            return;
        }
        self->_fixing = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setStatusSymbol:@"arrow.triangle.2.circlepath" fallback:@"⟳" tooltip:@"DisplayFixer: working…"];
        });
        DFLog(@"fix: start (%@, force=%d)", reason, force);
        NSString *summary = nil;
        DFResult r = DFRunFix(force, &summary);
        DFLog(@"fix: end result=%d (%@)", r, summary ?: @"");
        if (r == DFResultFixed) self->_lastFixEnd = NSProcessInfo.processInfo.systemUptime;  // cooldown only after a real reset
        self->_fixing = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshStatus]; });
    });
}

#pragma mark - menu / status

- (void)setStatusSymbol:(NSString *)name fallback:(NSString *)glyph tooltip:(NSString *)tip {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:tip];
    if (img) {
        _item.button.image = DFMenuBarImage(img);
        _item.button.imageScaling = NSImageScaleNone;
        _item.button.imagePosition = NSImageOnly;
        _item.button.title = @"";
    } else {
        _item.button.image = nil;
        _item.button.title = glyph;
    }
    _item.button.toolTip = tip;
}

- (void)refreshStatus {
    CGDirectDisplayID d = DFExternalDisplay();
    NSString *tip = DFStatusLine();
    if (d == kCGNullDirectDisplay)
        [self setStatusSymbol:@"display"                       fallback:@"⊝" tooltip:tip];  // no external display
    else if (DFIsDegraded(d))
        [self setStatusSymbol:@"exclamationmark.triangle.fill" fallback:@"▲" tooltip:tip];  // degraded
    else
        [self setStatusSymbol:@"checkmark.circle.fill"         fallback:@"✓" tooltip:tip];  // good
    if (_item.menu.itemArray.count) ((NSMenuItem *)_item.menu.itemArray.firstObject).title = tip;
}

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    NSMenuItem *status = [[NSMenuItem alloc] initWithTitle:DFStatusLine() action:nil keyEquivalent:@""];
    status.enabled = NO;
    [menu addItem:status];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Fix now" action:@selector(fixNow:) keyEquivalent:@"f"].target = self;

    NSMenuItem *wake = [[NSMenuItem alloc] initWithTitle:@"Fix automatically on wake" action:@selector(toggleRunOnWake:) keyEquivalent:@""];
    wake.target = self; wake.state = [ud boolForKey:kRunOnWakeKey] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:wake];

    NSMenuItem *every = [[NSMenuItem alloc] initWithTitle:@"Reset on every wake (vs. only when degraded)" action:@selector(toggleForceEveryWake:) keyEquivalent:@""];
    every.target = self; every.state = [ud boolForKey:kForceEveryWakeKey] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:every];

    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"Start at login" action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self; login.state = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:login];

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Open log" action:@selector(openLog:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Quit DisplayFixer" action:@selector(quit:) keyEquivalent:@"q"].target = self;

    _item.menu = menu;
}

#pragma mark - actions

- (void)fixNow:(id)sender { [self scheduleFixAfter:0 force:YES reason:@"manual"]; }

- (void)toggleRunOnWake:(id)sender {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:![ud boolForKey:kRunOnWakeKey] forKey:kRunOnWakeKey];
    [self rebuildMenu];
}

- (void)toggleForceEveryWake:(id)sender {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:![ud boolForKey:kForceEveryWakeKey] forKey:kForceEveryWakeKey];
    [self rebuildMenu];
}

- (void)toggleLogin:(id)sender {
    SMAppService *svc = SMAppService.mainAppService;
    NSError *err = nil;
    if (svc.status == SMAppServiceStatusEnabled) [svc unregisterAndReturnError:&err];
    else [svc registerAndReturnError:&err];
    if (err) DFLog(@"login toggle error: %@", err.localizedDescription);
    [self rebuildMenu];
}

- (NSString *)logFilePath {
    return [@"~/Library/Logs/DisplayFixer/displayfixer.log" stringByExpandingTildeInPath];
}

- (void)openLog:(id)sender {
    NSString *p = [self logFilePath];
    [[NSWorkspace sharedWorkspace] openURLs:@[[NSURL fileURLWithPath:p]]
                      withApplicationAtURL:[NSURL fileURLWithPath:@"/System/Applications/Utilities/Console.app"]
                             configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

@end
