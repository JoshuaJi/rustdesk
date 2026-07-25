#import <CoreFoundation/CoreFoundation.h>

// system-configuration 0.5 still references this legacy constant, which is no
// longer exported by current iOS SDKs.
CFStringRef const kSCNetworkInterfaceTypeIrDA = CFSTR("IrDA");
