// vmmreset.m — send the Synaptics VMM7100 "reset board" HID sequence over USB.
// Ports waydabber/vmm7100reset (shipped in BetterDisplay), itself from djrobx/USBResetter,
// reverse-engineered from Synaptics' Windows VMMHIDTool "Reset board" function.
//
// USB: VID 0x06CB (Synaptics) / PID 0x7100 (VMM7100). Three HID SET_REPORT control transfers
// (bmRequestType 0x21, bRequest 0x09, wValue 0x0201, wIndex 0, wLength 61), 1s apart.
// Packet 1 carries the ASCII "PRIUS" (50 52 49 55 53) chip-unlock code.
//
// Build: clang -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework IOKit vmmreset.m -o vmmreset
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <mach/mach_error.h>
#include <unistd.h>

static uint8_t P1[62] = {0x01,0x00,0x11,0x00,0x00,0x81,0x00,0x00,0x00,0x00,0x00,0x05,0x00,0x00,0x00,0x50,0x52,0x49,0x55,0x53,0xD6};
static uint8_t P2[62] = {0x01,0x00,0x0C,0x00,0x00,0xB1,0x00,0x2C,0x02,0x20,0x20,0x04,0x00,0x00,0x00,0xD1,0x20,0x00,0x71,[47]=0xB8};
static uint8_t P3[62] = {0x01,0x00,0x10,0x00,0x00,0xA1,0x00,0x1C,0x02,0x20,0x20,0x04,0x00,0x00,0x00,0xF5,0x00,0x00,0x00,0xF8,[47]=0x33};

static IOUSBDeviceInterface **findDevice(void){
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    SInt32 vid=0x06CB, pid=0x7100;
    CFNumberRef v=CFNumberCreate(NULL,kCFNumberSInt32Type,&vid), p=CFNumberCreate(NULL,kCFNumberSInt32Type,&pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v); CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    CFRelease(v); CFRelease(p);
    io_iterator_t it=0; if(IOServiceGetMatchingServices(kIOMainPortDefault,m,&it)!=KERN_SUCCESS) return NULL;
    io_service_t dev; IOUSBDeviceInterface **intf=NULL;
    while((dev=IOIteratorNext(it))){
        IOCFPlugInInterface **plug=NULL; SInt32 s=0;
        if(IOCreatePlugInInterfaceForService(dev,kIOUSBDeviceUserClientTypeID,kIOCFPlugInInterfaceID,&plug,&s)==KERN_SUCCESS && plug){
            (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (void**)&intf);
            (*plug)->Release(plug);
        }
        IOObjectRelease(dev); if(intf) break;
    }
    IOObjectRelease(it); return intf;
}
static IOUSBInterfaceInterface **getInterface(IOUSBDeviceInterface **dev){
    IOUSBFindInterfaceRequest fr; fr.bInterfaceClass=kIOUSBFindInterfaceDontCare; fr.bInterfaceSubClass=kIOUSBFindInterfaceDontCare;
    fr.bInterfaceProtocol=kIOUSBFindInterfaceDontCare; fr.bAlternateSetting=kIOUSBFindInterfaceDontCare;
    io_iterator_t it=0; if((*dev)->CreateInterfaceIterator(dev,&fr,&it)!=KERN_SUCCESS) return NULL;
    io_service_t u; IOUSBInterfaceInterface **intf=NULL;
    while((u=IOIteratorNext(it))){
        IOCFPlugInInterface **plug=NULL; SInt32 s=0;
        if(IOCreatePlugInInterfaceForService(u,kIOUSBInterfaceUserClientTypeID,kIOCFPlugInInterfaceID,&plug,&s)==KERN_SUCCESS && plug){
            (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (void**)&intf);
            (*plug)->Release(plug);
        }
        IOObjectRelease(u); if(intf) break;
    }
    IOObjectRelease(it); return intf;
}
int main(void){ @autoreleasepool {
    IOUSBDeviceInterface **dev=findDevice();
    if(!dev){ fprintf(stderr,"VMM7100 (06CB:7100) NOT found on USB\n"); return 1; }
    fprintf(stderr,"Found VMM7100 USB device.\n");
    IOUSBInterfaceInterface **intf=getInterface(dev);
    uint8_t *pk[3]={P1,P2,P3}; IOReturn o=kIOReturnError;
    if(intf){ o=(*intf)->USBInterfaceOpen(intf); fprintf(stderr,"USBInterfaceOpen=0x%08x (%s)\n",o,mach_error_string(o)); }
    else fprintf(stderr,"could not obtain interface\n");
    if(intf && o==kIOReturnSuccess){
        for(int i=0;i<3;i++){ IOUSBDevRequest r; r.bmRequestType=0x21;r.bRequest=0x09;r.wValue=0x0201;r.wIndex=0;r.wLength=61;r.pData=pk[i];r.wLenDone=0;
            IOReturn rr=(*intf)->ControlRequest(intf,0,&r); fprintf(stderr,"[iface] packet%d=0x%08x (%s) sent=%u\n",i+1,rr,mach_error_string(rr),r.wLenDone); if(i<2)sleep(1); }
        (*intf)->USBInterfaceClose(intf);
    } else {
        fprintf(stderr,"Falling back to device-level DeviceRequest...\n");
        IOReturn od=(*dev)->USBDeviceOpen(dev); fprintf(stderr,"USBDeviceOpen=0x%08x (%s)\n",od,mach_error_string(od));
        for(int i=0;i<3;i++){ IOUSBDevRequest r; r.bmRequestType=0x21;r.bRequest=0x09;r.wValue=0x0201;r.wIndex=0;r.wLength=61;r.pData=pk[i];r.wLenDone=0;
            IOReturn rr=(*dev)->DeviceRequest(dev,&r); fprintf(stderr,"[dev] packet%d=0x%08x (%s) sent=%u\n",i+1,rr,mach_error_string(rr),r.wLenDone); if(i<2)sleep(1); }
        if(od==kIOReturnSuccess)(*dev)->USBDeviceClose(dev);
    }
    if(intf)(*intf)->Release(intf); (*dev)->Release(dev); return 0;
}}
