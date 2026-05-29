#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
// Schedule a fix run on the serial queue after `delay` seconds.
- (void)scheduleFixAfter:(double)delay force:(BOOL)force reason:(NSString *)reason;
@end
