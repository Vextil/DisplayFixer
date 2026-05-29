@import Foundation;
@import IOKit;
typedef CFTypeRef IOAVVideoInterfaceRef;
extern IOAVVideoInterfaceRef IOAVVideoInterfaceCreateWithService(CFAllocatorRef, io_service_t);
extern IOAVVideoInterfaceRef IOAVVideoInterfaceCreateWithLocation(CFAllocatorRef, uint32_t);
extern CFTypeRef IOAVVideoInterfaceGetLinkData(IOAVVideoInterfaceRef);
static io_service_t extNode(void){
  io_iterator_t it=0; if(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it)!=KERN_SUCCESS) return 0;
  io_service_t s,found=0; while((s=IOIteratorNext(it))){ CFTypeRef loc=IORegistryEntrySearchCFProperty(s,kIOServicePlane,CFSTR("Location"),kCFAllocatorDefault,kIORegistryIterateRecursively);
    BOOL e=(loc&&CFGetTypeID(loc)==CFStringGetTypeID()&&CFStringCompare(loc,CFSTR("External"),0)==kCFCompareEqualTo); if(loc)CFRelease(loc);
    if(e){found=s;break;} IOObjectRelease(s);} IOObjectRelease(it); return found; }
int main(void){@autoreleasepool{
  io_service_t n=extNode();
  IOAVVideoInterfaceRef vi = n?IOAVVideoInterfaceCreateWithService(kCFAllocatorDefault,n):NULL;
  for(uint32_t l=0;l<4&&!vi;l++) vi=IOAVVideoInterfaceCreateWithLocation(kCFAllocatorDefault,l);
  if(!vi){fprintf(stderr,"no VideoInterface\n");return 1;}
  CFTypeRef ld = IOAVVideoInterfaceGetLinkData(vi);
  fprintf(stderr,"GetLinkData ptr=%p\n",(void*)ld);
  if(ld){ unsigned long t=CFGetTypeID(ld);
    fprintf(stderr,"typeID=%lu  (CFData=%lu CFDict=%lu CFString=%lu CFArray=%lu)\n",t,CFDataGetTypeID(),CFDictionaryGetTypeID(),CFStringGetTypeID(),CFArrayGetTypeID());
    CFShow(ld); }
  return 0; }}
