// Standalone probe for the DCP framebuffer's "digital out mode" (= active connection colour mode).
// See research/direct-set-digitaloutmode.md for the full writeup and caveats.
//
// Build: clang -fobjc-arc -fmodules -F"$(xcrun --sdk macosx --show-sdk-path)/System/Library/PrivateFrameworks" \
//          -framework Foundation -framework IOKit -framework IOMobileFramebuffer research/digitaloutmode.m -o /tmp/dom
// Read:  /tmp/dom
// Set:   /tmp/dom set <a> <b>     (DANGER: only when that mode is currently available, else KERNEL PANIC)
//
// On the test Samsung 4K@165: a=10208 8bit YCbCr422, a=10212 10bit RGB, a=10219 10bit YCbCr444, b=10199.

@import Foundation; @import IOKit;
#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>
typedef struct __IOMFB *IOMobileFramebufferRef;
extern kern_return_t IOMobileFramebufferOpen(io_service_t, task_port_t, uint32_t, IOMobileFramebufferRef*);
extern kern_return_t IOMobileFramebufferGetDigitalOutMode(IOMobileFramebufferRef, uint32_t*, uint32_t*);
extern kern_return_t IOMobileFramebufferSetDigitalOutMode(IOMobileFramebufferRef, uint32_t, uint32_t);

// First external==YES IOMobileFramebufferShim with a real DisplayAttributes (never the builtin).
static io_service_t extFB(void){
  io_iterator_t it=0; IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &it);
  io_service_t s, found=0;
  while((s=IOIteratorNext(it))){
    CFTypeRef e=IORegistryEntryCreateCFProperty(s,CFSTR("external"),kCFAllocatorDefault,0);
    BOOL ext=(e&&CFGetTypeID(e)==CFBooleanGetTypeID()&&CFBooleanGetValue(e)); if(e)CFRelease(e);
    CFTypeRef da=IORegistryEntryCreateCFProperty(s,CFSTR("DisplayAttributes"),kCFAllocatorDefault,0);
    BOOL real=(da&&CFGetTypeID(da)==CFDictionaryGetTypeID()&&CFDictionaryGetValue((CFDictionaryRef)da,CFSTR("ProductAttributes"))); if(da)CFRelease(da);
    if(ext&&real&&!found){found=s;IOObjectRetain(found);} IOObjectRelease(s);
  } IOObjectRelease(it); return found;
}
int main(int argc,char**argv){@autoreleasepool{
  io_service_t svc=extFB(); if(!svc){fprintf(stderr,"no external framebuffer\n");return 1;}
  IOMobileFramebufferRef fb=NULL; kern_return_t kr=IOMobileFramebufferOpen(svc,mach_task_self(),0,&fb);
  if(kr||!fb){fprintf(stderr,"Open kr=0x%x\n",kr);IOObjectRelease(svc);return 1;}
  uint32_t a=0,b=0; fprintf(stderr,"GetDigitalOutMode kr=0x%x  a=%u b=%u\n", IOMobileFramebufferGetDigitalOutMode(fb,&a,&b), a, b);
  if(argc>=4 && strcmp(argv[1],"set")==0){
    uint32_t na=(uint32_t)strtoul(argv[2],0,10), nb=(uint32_t)strtoul(argv[3],0,10);
    fprintf(stderr,"SetDigitalOutMode(%u,%u) -> 0x%x\n", na, nb, IOMobileFramebufferSetDigitalOutMode(fb,na,nb));
  }
  IOObjectRelease(svc); return 0;
}}
