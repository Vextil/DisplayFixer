// hdrfix.m — read external display format + HDR state; optionally toggle HDR (the proven fix).
// Build:
//   clang -fobjc-arc -fmodules -Wno-deprecated-declarations \
//     -F"$(xcrun --sdk macosx --show-sdk-path)/System/Library/PrivateFrameworks" \
//     -framework Foundation -framework CoreGraphics -framework SkyLight hdrfix.m -o hdrfix
// Run:
//   ./hdrfix          # READ-ONLY: depth / current-mode channels / HDR state / #10-bit 4K modes offered
//   ./hdrfix on       # enable HDR
//   ./hdrfix off      # disable HDR
//   ./hdrfix cycle    # enable HDR, wait, disable HDR  (automates the proven 10-bit-4:4:4 restore)
@import Foundation;
@import CoreGraphics;

typedef int CGSError;
extern CGSError SLSGetDisplayDepth(CGDirectDisplayID, int*);
extern CGSError SLSGetDisplayPixelEncodingOfLength(CGDirectDisplayID, char*, unsigned long);
extern CGSError SLSGetCurrentDisplayMode(CGDirectDisplayID, int*);
extern CGSError SLSGetDisplayModeDescriptionOfLength(CGDirectDisplayID, int, void*, int);
extern int      SLSDisplayIsHDRModeEnabled(CGDirectDisplayID);
extern int      SLSDisplaySupportsHDRMode(CGDirectDisplayID);
extern CGSError SLSDisplaySetHDRModeEnabled(CGDirectDisplayID, bool);

static CGDirectDisplayID externalDisplay(void){
    uint32_t n=0; CGGetActiveDisplayList(0,NULL,&n);
    CGDirectDisplayID ids[16]; if(n>16)n=16; CGGetActiveDisplayList(n,ids,&n);
    for(uint32_t i=0;i<n;i++) if(!CGDisplayIsBuiltin(ids[i])) return ids[i];
    return kCGNullDirectDisplay;
}

// Decode current mode's 212-byte CGSDisplayModeDescription (layout verified on M4/26.x):
//   u32[2]=w u32[3]=h u32[6]=bpp u32[7]=bpc u32[8]=encEnum u32[9]=Hz ; bytes[48..]=channel map.
static void decodeCurrentMode(CGDirectDisplayID d){
    int cur=-1; if(SLSGetCurrentDisplayMode(d,&cur)!=0||cur<0){printf("  curMode: (unavailable)\n");return;}
    uint8_t desc[256]; memset(desc,0,sizeof desc);
    if(SLSGetDisplayModeDescriptionOfLength(d,cur,desc,212)!=0){printf("  curMode: (desc failed)\n");return;}
    const uint32_t*u=(const uint32_t*)desc; char ch[33]={0}; memcpy(ch,desc+48,32);
    printf("  curMode[%d]: %ux%u@%uHz bpp=%u bpc=%u encEnum=%u channels=\"%s\"\n",
           cur,u[2],u[3],u[9],u[6],u[7],u[8],ch);
}

static void report(CGDirectDisplayID d,const char*when){
    int depth=-1; SLSGetDisplayDepth(d,&depth);
    char enc[256]={0}; SLSGetDisplayPixelEncodingOfLength(d,enc,sizeof enc);
    int hdrOn=SLSDisplayIsHDRModeEnabled(d), hdrSup=SLSDisplaySupportsHDRMode(d);
    CFDictionaryRef opt=(__bridge CFDictionaryRef)@{(__bridge NSString*)kCGDisplayShowDuplicateLowResolutionModes:@YES};
    CFArrayRef modes=CGDisplayCopyAllDisplayModes(d,opt); int tenbit=0,tot=0;
    if(modes){for(CFIndex k=0;k<CFArrayGetCount(modes);k++){CGDisplayModeRef mm=(CGDisplayModeRef)CFArrayGetValueAtIndex(modes,k);
        if(CGDisplayModeGetPixelWidth(mm)<3840)continue; tot++;
        CFStringRef en=CGDisplayModeCopyPixelEncoding(mm);
        if(en){char b[128]={0};CFStringGetCString(en,b,sizeof b,kCFStringEncodingUTF8);CFRelease(en);
               if(strstr(b,"RRRRRRRRRR"))tenbit++;}}
        CFRelease(modes);}
    printf("[%-8s] SLSdepth=%d HDRsup=%d HDRon=%d  10bit-4K-modes=%d/%d  SLSenc=\"%s\"\n",
           when,depth,hdrSup,hdrOn,tenbit,tot,enc);
    decodeCurrentMode(d);
}

int main(int argc,char**argv){@autoreleasepool{
    CGDirectDisplayID d=externalDisplay();
    if(d==kCGNullDirectDisplay){fprintf(stderr,"no external display\n");return 1;}
    printf("External display 0x%x\n",d);
    const char*cmd=argc>1?argv[1]:"";
    report(d,"before");
    if(!strcmp(cmd,"on")){printf("SetHDR(true)=%d\n",SLSDisplaySetHDRModeEnabled(d,true));usleep(2000000);report(d,"after-on");}
    else if(!strcmp(cmd,"off")){printf("SetHDR(false)=%d\n",SLSDisplaySetHDRModeEnabled(d,false));usleep(2000000);report(d,"after-off");}
    else if(!strcmp(cmd,"cycle")){
        printf("SetHDR(true)=%d\n",SLSDisplaySetHDRModeEnabled(d,true)); usleep(2500000); report(d,"hdr-on");
        printf("SetHDR(false)=%d\n",SLSDisplaySetHDRModeEnabled(d,false)); usleep(2500000); report(d,"hdr-off");
    } else printf("(read-only; pass on|off|cycle)\n");
    return 0;
}}
