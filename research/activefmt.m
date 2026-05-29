@import Foundation;
@import IOKit;
typedef CFTypeRef IOAVVideoInterfaceRef;
extern IOAVVideoInterfaceRef IOAVVideoInterfaceCreateWithService(CFAllocatorRef, io_service_t);
extern IOAVVideoInterfaceRef IOAVVideoInterfaceCreateWithLocation(CFAllocatorRef, uint32_t);
extern CFArrayRef IOAVVideoInterfaceCopyColorElements(IOAVVideoInterfaceRef);
extern CFDictionaryRef IOAVVideoInterfaceCopyProperties(IOAVVideoInterfaceRef);
extern CFStringRef IOAVVideoInterfaceCopyDiagnosticsString(IOAVVideoInterfaceRef);

static io_service_t extNode(void){
  io_iterator_t it=0; if(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it)!=KERN_SUCCESS) return 0;
  io_service_t s,found=0;
  while((s=IOIteratorNext(it))){ CFTypeRef loc=IORegistryEntrySearchCFProperty(s,kIOServicePlane,CFSTR("Location"),kCFAllocatorDefault,kIORegistryIterateRecursively);
    BOOL e=(loc&&CFGetTypeID(loc)==CFStringGetTypeID()&&CFStringCompare(loc,CFSTR("External"),0)==kCFCompareEqualTo); if(loc)CFRelease(loc);
    if(e){found=s;break;} IOObjectRelease(s);} IOObjectRelease(it); return found;
}
static long num(CFDictionaryRef d, CFStringRef k){ long n=-1; CFNumberRef v=CFDictionaryGetValue(d,k); if(v&&CFGetTypeID(v)==CFNumberGetTypeID())CFNumberGetValue(v,kCFNumberLongType,&n); return n; }
int main(void){@autoreleasepool{
  io_service_t n=extNode();
  IOAVVideoInterfaceRef vi = n?IOAVVideoInterfaceCreateWithService(kCFAllocatorDefault,n):NULL;
  for(uint32_t l=0;l<4&&!vi;l++) vi=IOAVVideoInterfaceCreateWithLocation(kCFAllocatorDefault,l);
  if(!vi){fprintf(stderr,"no VideoInterface\n");return 1;}
  fprintf(stderr,"=== ColorElements (raw; enc 0=RGB seen earlier, 3=YCbCr) ===\n");
  CFArrayRef ce=IOAVVideoInterfaceCopyColorElements(vi);
  if(ce){ for(CFIndex i=0;i<CFArrayGetCount(ce);i++){ CFDictionaryRef e=CFArrayGetValueAtIndex(ce,i);
    if(CFGetTypeID(e)!=CFDictionaryGetTypeID()) continue;
    fprintf(stderr,"  ID=%ld depth=%ld enc=%ld DSC=%ld virtual=%ld score=%ld\n",
      num(e,CFSTR("ID")),num(e,CFSTR("Depth")),num(e,CFSTR("PixelEncoding")),num(e,CFSTR("SupportsDSC")),num(e,CFSTR("IsVirtual")),num(e,CFSTR("Score"))); }
    CFRelease(ce);}
  fprintf(stderr,"\n=== DiagnosticsString ===\n");
  CFStringRef diag=IOAVVideoInterfaceCopyDiagnosticsString(vi); if(diag){CFShow(diag);CFRelease(diag);} else fprintf(stderr,"(nil)\n");
  fprintf(stderr,"\n=== Properties keys ===\n");
  CFDictionaryRef p=IOAVVideoInterfaceCopyProperties(vi); if(p){CFShow(p);CFRelease(p);} else fprintf(stderr,"(nil)\n");
  CFRelease(vi); if(n)IOObjectRelease(n); return 0;
}}
