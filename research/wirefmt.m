// wirefmt.m — READ-ONLY: dump the External display's actual WIRE color format from the DCP.
@import Foundation;
@import IOKit;
typedef CFTypeRef IOAVVideoInterfaceRef;
extern IOAVVideoInterfaceRef IOAVVideoInterfaceCreateWithService(CFAllocatorRef, io_service_t);
extern IOAVVideoInterfaceRef IOAVVideoInterfaceCreateWithLocation(CFAllocatorRef, uint32_t);
extern CFArrayRef IOAVVideoInterfaceCopyColorElements(IOAVVideoInterfaceRef);
extern CFArrayRef IOAVVideoInterfaceCopyTimingElements(IOAVVideoInterfaceRef);
extern CFDictionaryRef IOAVVideoInterfaceCopyDisplayAttributes(IOAVVideoInterfaceRef);
extern CFStringRef IOAVVideoInterfaceGetLocation(IOAVVideoInterfaceRef);

static io_service_t externalAVNode(void){
  io_iterator_t it=0;
  if(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it)!=KERN_SUCCESS) return 0;
  io_service_t s, found=0;
  while((s=IOIteratorNext(it))){
    CFTypeRef loc=IORegistryEntrySearchCFProperty(s,kIOServicePlane,CFSTR("Location"),kCFAllocatorDefault,kIORegistryIterateRecursively);
    BOOL ext=(loc&&CFGetTypeID(loc)==CFStringGetTypeID()&&CFStringCompare(loc,CFSTR("External"),0)==kCFCompareEqualTo);
    if(loc)CFRelease(loc);
    if(ext){found=s;break;} IOObjectRelease(s);
  }
  IOObjectRelease(it); return found;
}
static void d(const char*l, CFTypeRef v){ fprintf(stderr,"---- %s ----\n",l); if(v) CFShow(v); else fprintf(stderr,"(null)\n"); }

int main(void){@autoreleasepool{
  io_service_t node=externalAVNode();
  fprintf(stderr,"External DCPAVServiceProxy node=0x%x\n",node);
  IOAVVideoInterfaceRef vi = node? IOAVVideoInterfaceCreateWithService(kCFAllocatorDefault,node):NULL;
  fprintf(stderr,"VI via CreateWithService=%p\n",(void*)vi);
  for(uint32_t loc=0; loc<4 && !vi; loc++){ vi=IOAVVideoInterfaceCreateWithLocation(kCFAllocatorDefault,loc); fprintf(stderr,"VI via CreateWithLocation(%u)=%p\n",loc,(void*)vi);}
  if(!vi){fprintf(stderr,"no IOAVVideoInterface\n"); if(node)IOObjectRelease(node); return 1;}
  d("Location", IOAVVideoInterfaceGetLocation(vi));
  CFArrayRef ce=IOAVVideoInterfaceCopyColorElements(vi); d("ColorElements",ce); if(ce)CFRelease(ce);
  CFDictionaryRef da=IOAVVideoInterfaceCopyDisplayAttributes(vi); d("DisplayAttributes",da); if(da)CFRelease(da);
  CFArrayRef te=IOAVVideoInterfaceCopyTimingElements(vi); d("TimingElements",te); if(te)CFRelease(te);
  CFRelease(vi); if(node)IOObjectRelease(node); return 0;
}}
