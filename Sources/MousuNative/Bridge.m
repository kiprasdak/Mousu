#import "MousuNative.h"
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDDevice.h>
#import <IOKit/hid/IOHIDKeys.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <string.h>

struct MousuHID {
    IOHIDEventSystemClientRef client;
    CFMutableDictionaryRef deviceMetadata;
};

static IOHIDEventSystemClientRef createPropertyClient(void) {
    IOHIDEventSystemClientRef (*createClient)(CFAllocatorRef) = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    return createClient ? createClient(kCFAllocatorDefault) : NULL;
}

static CFArrayRef copyPropertyServices(IOHIDEventSystemClientRef client) {
    return IOHIDEventSystemClientCopyServices(client);
}

static io_registry_entry_t copyPhysicalDeviceEntry(IOHIDServiceClientRef service) {
    id registryID = (__bridge id)IOHIDServiceClientGetRegistryID(service);
    if (![registryID isKindOfClass:NSNumber.class]) return IO_OBJECT_NULL;
    io_registry_entry_t entry = IOServiceGetMatchingService(kIOMainPortDefault,
        IORegistryEntryIDMatching([registryID unsignedLongLongValue]));
    for (unsigned depth=0; entry && depth<16; depth++) {
        if (IOObjectConformsTo(entry, "IOHIDDevice")) return entry;
        io_registry_entry_t next = 0;
        IORegistryEntryGetParentEntry(entry, kIOServicePlane, &next);
        IOObjectRelease(entry);
        entry = next;
    }
    if (entry) IOObjectRelease(entry);
    return IO_OBJECT_NULL;
}

static NSNumber *registryNumber(io_registry_entry_t entry) {
    uint64_t value = 0;
    return entry && IORegistryEntryGetRegistryEntryID(entry, &value) == KERN_SUCCESS ? @(value) : nil;
}

static NSNumber *usbDeviceRegistryNumber(io_registry_entry_t physical) {
    if (!physical) return nil;
    io_registry_entry_t entry = physical;
    IOObjectRetain(entry);
    NSNumber *result = nil;
    for (unsigned depth=0; entry && depth<16; depth++) {
        if (IOObjectConformsTo(entry, "IOUSBHostDevice") || IOObjectConformsTo(entry, "IOUSBDevice")) {
            result = registryNumber(entry);
            break;
        }
        io_registry_entry_t next = 0;
        IORegistryEntryGetParentEntry(entry, kIOServicePlane, &next);
        IOObjectRelease(entry);
        entry = next;
    }
    if (entry) IOObjectRelease(entry);
    return result;
}

static BOOL registryServiceExists(uint64_t registryID) {
    io_registry_entry_t entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID));
    if (!entry) return NO;
    IOObjectRelease(entry);
    return YES;
}

typedef struct {
    BOOL x;
    BOOL y;
    BOOL uncertainOrAbsolute;
    unsigned budget;
} RelativeAxisScan;

static void inspectRelativeAxes(id elements, unsigned depth, RelativeAxisScan *scan) {
    if (![elements isKindOfClass:NSArray.class] || depth > 12) {
        scan->uncertainOrAbsolute = YES;
        return;
    }
    for (id object in elements) {
        if (!scan->budget || ![object isKindOfClass:NSDictionary.class]) {
            scan->uncertainOrAbsolute = YES;
            return;
        }
        --scan->budget;
        NSDictionary *element = object;
        NSNumber *type = element[@kIOHIDElementTypeKey];
        NSNumber *page = element[@kIOHIDElementUsagePageKey];
        NSNumber *usage = element[@kIOHIDElementUsageKey];
        if (![type isKindOfClass:NSNumber.class] || ![page isKindOfClass:NSNumber.class]
            || ![usage isKindOfClass:NSNumber.class]) {
            scan->uncertainOrAbsolute = YES;
            return;
        }
        BOOL input = type.unsignedIntValue >= kIOHIDElementTypeInput_Misc
            && type.unsignedIntValue <= kIOHIDElementTypeInput_ScanCodes;
        if (input && page.unsignedIntValue == 1
            && (usage.unsignedIntValue == 0x30 || usage.unsignedIntValue == 0x31)) {
            NSNumber *relative = element[@kIOHIDElementIsRelativeKey];
            if (![relative isKindOfClass:NSNumber.class] || !relative.boolValue) {
                scan->uncertainOrAbsolute = YES;
                return;
            }
            scan->x = scan->x || usage.unsignedIntValue == 0x30;
            scan->y = scan->y || usage.unsignedIntValue == 0x31;
        }
        id children = element[@kIOHIDElementKey];
        if (children) {
            inspectRelativeAxes(children, depth+1, scan);
            if (scan->uncertainOrAbsolute) return;
        }
    }
}

static BOOL hasRelativeAxes(IOHIDServiceClientRef service) {
    io_registry_entry_t entry = copyPhysicalDeviceEntry(service);
    if (!entry) return NO;
    // IOHIDKeys documents this hierarchical registry metadata; Apple's
    // IOHIDElementPrivate::createProperties derives IsRelative from report flags.
    // CopyMatchingElements may require a HID user client even for metadata, so
    // inspect the published dictionaries without creating or opening a device.
    // Reading the complete property dictionary preserves nested element
    // collections; the single-property serializer can omit collection children.
    CFMutableDictionaryRef properties = NULL;
    IOReturn status = IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0);
    NSDictionary *metadata = CFBridgingRelease(properties);
    id elements = status == kIOReturnSuccess ? metadata[@kIOHIDElementKey] : nil;
    IOObjectRelease(entry);
    RelativeAxisScan scan = {.budget = 4096};
    inspectRelativeAxes(elements, 0, &scan);
    // Mixed relative/absolute devices remain conservative until their individual
    // collections can be authenticated to the particular event service.
    return scan.x && scan.y && !scan.uncertainOrAbsolute;
}

bool MousuRequestAccessibility(void) {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

static id property(IOHIDServiceClientRef service, NSString *key) {
    id value = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, (__bridge CFStringRef)key));
    if (value) return value;
    id registryID = (__bridge id)IOHIDServiceClientGetRegistryID(service);
    if (![registryID isKindOfClass:NSNumber.class]) return nil;
    io_service_t entry = IOServiceGetMatchingService(kIOMainPortDefault,
        IORegistryEntryIDMatching([registryID unsignedLongLongValue]));
    if (!entry) return nil;
    value = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, (__bridge CFStringRef)key, kCFAllocatorDefault, 0));
    if (!value) {
        id cached = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("HIDEventServiceProperties"), kCFAllocatorDefault, 0));
        if ([cached isKindOfClass:NSDictionary.class]) value = cached[key];
    }
    // Only identity/classification metadata may be inherited from a parent.
    // Never take a pointer property's baseline from a global ancestor.
    if (!value && [@[@"SerialNumber", @"PhysicalDeviceUniqueID", @"DeviceUID", @"Built-In", @"LocationID", @"Manufacturer", @"Product", @"VendorID", @"ProductID", @"Transport"] containsObject:key]) {
        io_registry_entry_t parent = entry;
        IOObjectRetain(parent);
        for (unsigned depth=0; parent && depth<16; depth++) {
            if (IOObjectConformsTo(parent, "IOHIDDevice")) {
                // Identity metadata is already published in the registry.
                // Avoid creating an HID user client for each missing field.
                value = CFBridgingRelease(IORegistryEntryCreateCFProperty(
                    parent, (__bridge CFStringRef)key, kCFAllocatorDefault, 0));
                break;
            }
            io_registry_entry_t next = 0;
            IORegistryEntryGetParentEntry(parent, kIOServicePlane, &next);
            IOObjectRelease(parent);
            parent = next;
        }
        if (parent) IOObjectRelease(parent);
    }
    IOObjectRelease(entry);
    return value;
}

static BOOL external(IOHIDServiceClientRef service) {
    id builtIn = property(service, @"Built-In");
    if ([builtIn respondsToSelector:@selector(boolValue)] && [builtIn boolValue]) return NO;
    NSString *transport = property(service, @"Transport");
    if (![transport isKindOfClass:NSString.class]) return NO;
    BOOL connected = [@[@"USB", @"Bluetooth", @"Bluetooth Low Energy", @"BluetoothLowEnergy"] containsObject:transport];
    BOOL pointer = IOHIDServiceClientConformsTo(service, 1, 2)
                || IOHIDServiceClientConformsTo(service, 1, 1)
                || IOHIDServiceClientConformsTo(service, 13, 5);
    return connected && pointer;
}

MousuHID *MousuHIDCreate(void) {
    // The public simple client refuses the linear-scaling property. This
    // runtime-checked client is used only for discovery/property access: never
    // register an HID event callback or open a raw input device.
    IOHIDEventSystemClientRef client = createPropertyClient();
    if (!client) return NULL;
    MousuHID *context = calloc(1, sizeof(MousuHID));
    if (!context) { CFRelease(client); return NULL; }
    context->client = client;
    context->deviceMetadata = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!context->deviceMetadata) { CFRelease(client); free(context); return NULL; }
    return context;
}

MousuHID *MousuHIDTakePropertyContext(MousuHID *context) {
    if (!context->client) return NULL;
    MousuHID *properties = calloc(1, sizeof(MousuHID));
    if (!properties) return NULL;
    properties->deviceMetadata = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, context->deviceMetadata);
    if (!properties->deviceMetadata) { free(properties); return NULL; }
    properties->client = context->client;
    context->client = NULL;
    return properties;
}

void MousuHIDDestroy(MousuHID *context) {
    if (context->client) CFRelease(context->client);
    CFRelease(context->deviceMetadata);
    free(context);
}

CFArrayRef MousuCopyDevices(MousuHID *context) {
    @autoreleasepool {
        // An unscheduled event-system client caches its service inventory.
        // Refresh the property-only client so hotplug does not require an event
        // subscription or run-loop callback. Keep the old client on failure so
        // already-owned properties can still be restored against live services.
        IOHIDEventSystemClientRef fresh = createPropertyClient();
        if (!fresh) return NULL;
        CFArrayRef copied = copyPropertyServices(fresh);
        if (!copied) { CFRelease(fresh); return NULL; }
        NSArray *services = CFBridgingRelease(copied);
        IOHIDEventSystemClientRef previous = context->client;
        context->client = fresh;
        if (previous) CFRelease(previous);
        NSMutableArray *result = [NSMutableArray array];
        NSMutableDictionary *nextMetadata = [NSMutableDictionary dictionary];
        for (id object in services) {
            IOHIDServiceClientRef service = (__bridge IOHIDServiceClientRef)object;
            BOOL pointer = IOHIDServiceClientConformsTo(service, 1, 2)
                        || IOHIDServiceClientConformsTo(service, 1, 1)
                        || IOHIDServiceClientConformsTo(service, 13, 5);
            if (!pointer) continue;
            id registryID = (__bridge id)IOHIDServiceClientGetRegistryID(service);
            if (![registryID isKindOfClass:NSNumber.class]) continue;
            NSDictionary *cached = (__bridge NSDictionary *)CFDictionaryGetValue(
                context->deviceMetadata, (__bridge CFTypeRef)registryID);
            NSMutableDictionary *row = [cached mutableCopy];
            if (!row) {
                row = [@{@"RegistryID":registryID, @"External":@(external(service)),
                         @"RelativePointer":@(hasRelativeAxes(service)),
                         @"IsTouchpad":@(IOHIDServiceClientConformsTo(service, 13, 5))} mutableCopy];
                for (NSString *key in @[@"Product", @"Manufacturer", @"Transport", @"VendorID", @"ProductID", @"SerialNumber",
                                        @"PhysicalDeviceUniqueID", @"DeviceUID", @"LocationID", @"Built-In",
                                        @"HIDPointerAccelerationType", @"HIDPointerResolution", @"HIDScrollAccelerationType"]) {
                    id value = property(service, key);
                    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) row[key] = value;
                }
                // These registry IDs identify only this connection. A compound
                // USB mouse's interfaces share its USB device ancestor; identical
                // mice connected separately have distinct ancestors.
                io_registry_entry_t physical = copyPhysicalDeviceEntry(service);
                NSNumber *physicalID = registryNumber(physical);
                if (physicalID) row[@"PhysicalDeviceRegistryID"] = physicalID;
                if ([row[@"Transport"] isEqualToString:@"USB"]) {
                    NSNumber *usbID = usbDeviceRegistryNumber(physical);
                    if (usbID) row[@"USBDeviceRegistryID"] = usbID;
                }
                if (physical) IOObjectRelease(physical);
            }
            nextMetadata[registryID] = [row copy];
            // Cache identity/classification only. Ownership and UI always see
            // freshly read pointer values, including competing utility changes.
            for (NSString *key in @[@"HIDUseLinearScalingMouseAcceleration", @"HIDPointerAcceleration",
                                    @"HIDMouseAcceleration", @"HIDTrackpadAcceleration", @"HIDMouseScrollAcceleration"]) {
                id value = property(service, key);
                if ([value isKindOfClass:NSNumber.class]) row[key] = value;
            }
            [result addObject:row];
        }
        // Prune only after a successful inventory, never after discovery failure.
        CFMutableDictionaryRef updated = CFDictionaryCreateMutableCopy(
            kCFAllocatorDefault, 0, (__bridge CFDictionaryRef)nextMetadata);
        if (updated) {
            CFRelease(context->deviceMetadata);
            context->deviceMetadata = updated;
        }
        return CFBridgingRetain(result);
    }
}

static IOHIDServiceClientRef copyExternalService(MousuHID *context, uint64_t registryID) {
    if (!context->client) return NULL;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(context->client);
    if (!services) return NULL;
    IOHIDServiceClientRef found = NULL;
    for (CFIndex i=0; i<CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        id value = (__bridge id)IOHIDServiceClientGetRegistryID(service);
        if ([value isKindOfClass:NSNumber.class] && [value unsignedLongLongValue] == registryID
            && registryServiceExists(registryID) && external(service)) {
            found = (IOHIDServiceClientRef)CFRetain(service); break;
        }
    }
    CFRelease(services);
    return found;
}

static BOOL allowedKey(IOHIDServiceClientRef service, NSString *key) {
    NSString *type = property(service, @"HIDPointerAccelerationType");
    return [type isKindOfClass:NSString.class] && [type isEqualToString:@"HIDMouseAcceleration"] &&
        ([key isEqualToString:@"HIDUseLinearScalingMouseAcceleration"] || [key isEqualToString:type]);
}

bool MousuReadNumber(MousuHID *context, uint64_t registryID, const char *key, int64_t *value) {
    @autoreleasepool {
        IOHIDServiceClientRef service = copyExternalService(context, registryID);
        if (!service) return false;
        NSString *name = [NSString stringWithUTF8String:key];
        id number = allowedKey(service, name) ? property(service, name) : nil;
        BOOL valid = [number isKindOfClass:NSNumber.class];
        if (valid) *value = [number longLongValue];
        CFRelease(service);
        return valid;
    }
}

bool MousuNumberIsRestorable(const char *key, int64_t value) {
    if (strcmp(key, "HIDUseLinearScalingMouseAcceleration") == 0) return value == 0 || value == 1;
    if (strcmp(key, "HIDMouseAcceleration") == 0) return value >= -65536 && value <= 40LL * 65536;
    return false;
}

bool MousuWriteNumber(MousuHID *context, uint64_t registryID, const char *key, int64_t value) {
    @autoreleasepool {
        IOHIDServiceClientRef service = copyExternalService(context, registryID);
        if (!service) return false;
        NSString *name = [NSString stringWithUTF8String:key];
        BOOL valid = allowedKey(service, name) && MousuNumberIsRestorable(key, value);
        BOOL success = valid && registryServiceExists(registryID)
            && IOHIDServiceClientSetProperty(service, (__bridge CFStringRef)name, (__bridge CFNumberRef)@(value));
        CFRelease(service);
        return success;
    }
}

// Undocumented ABI is confined here. Symbol absence disables routing; no fallback
// to 'last active device'. Constants are verified against Apple's IOHIDFamily.
static CFTypeRef (*copyHID)(CGEventRef);
static uint64_t (*senderID)(CFTypeRef);
static uint32_t (*eventType)(CFTypeRef);
static uint32_t (*eventFlags)(CFTypeRef);
static double (*floatValue)(CFTypeRef, uint32_t);
static void (*setFloatValue)(CFTypeRef, uint32_t, double);
static CFArrayRef (*children)(CFTypeRef);
static pthread_once_t symbolsOnce = PTHREAD_ONCE_INIT;
static void loadSymbols(void) {
    copyHID = dlsym(RTLD_DEFAULT, "CGEventCopyIOHIDEvent");
    senderID = dlsym(RTLD_DEFAULT, "IOHIDEventGetSenderID");
    eventType = dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    eventFlags = dlsym(RTLD_DEFAULT, "IOHIDEventGetEventFlags");
    floatValue = dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
    setFloatValue = dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
    children = dlsym(RTLD_DEFAULT, "IOHIDEventGetChildren");
}
bool MousuEventBridgeAvailable(void) {
    pthread_once(&symbolsOnce, loadSymbols);
    return copyHID && senderID && eventType && eventFlags && floatValue && setFloatValue && children;
}

static void findRawScroll(CFTypeRef event, unsigned depth, unsigned *budget, CFTypeRef *found, unsigned *matches) {
    if (depth > 4 || !*budget) { *matches = 2; return; }
    --*budget;
    if (eventType(event) == 6 && !(eventFlags(event) & 0x00010000)) { *found = event; ++*matches; }
    CFArrayRef nodes = children(event);
    if (!nodes) return;
    // Bound work even for malformed/unexpected event trees.
    CFIndex count = MIN(CFArrayGetCount(nodes), 16);
    if (CFArrayGetCount(nodes) > 16) *matches = 2;
    for (CFIndex i=0; i<count; i++) {
        findRawScroll(CFArrayGetValueAtIndex(nodes, i), depth+1, budget, found, matches);
        if (*matches > 1) return;
    }
}

MousuEventSource MousuGetEventSource(CGEventRef event) {
    MousuEventSource result = {0};
    if (!MousuEventBridgeAvailable()) return result;
    CFTypeRef hid = copyHID(event);
    if (!hid) return result;
    result.senderID = senderID(hid);
    CFTypeRef raw = NULL;
    unsigned budget = 64, matches = 0;
    findRawScroll(hid, 0, &budget, &raw, &matches);
    if (raw && matches == 1 && (!result.senderID || !senderID(raw) || result.senderID == senderID(raw))) {
        result.rawX = floatValue(raw, 6U << 16);
        result.rawY = floatValue(raw, (6U << 16) | 1);
        result.hasRawScroll = isfinite(result.rawX) && isfinite(result.rawY)
            && fabs(result.rawX) <= 10000 && fabs(result.rawY) <= 10000;
        if (!result.senderID) result.senderID = senderID(raw);
    }
    CFRelease(hid);
    return result;
}

static void syncTree(CFTypeRef event, bool fixed, double x, double y, unsigned depth) {
    if (depth > 4) return;
    if (eventType(event) == 6) {
        setFloatValue(event, 6U<<16, fixed ? x : floatValue(event, 6U<<16)*x);
        setFloatValue(event, (6U<<16)|1, fixed ? y : floatValue(event, (6U<<16)|1)*y);
    }
    CFArrayRef nodes = children(event);
    if (!nodes) return;
    for (CFIndex i=0, count=MIN(CFArrayGetCount(nodes),16); i<count; i++)
        syncTree(CFArrayGetValueAtIndex(nodes,i), fixed, x, y, depth+1);
}
void MousuSyncScroll(CGEventRef event, bool fixed, double x, double y) {
    if (!MousuEventBridgeAvailable()) return;
    CFTypeRef hid = copyHID(event);
    if (!hid) return;
    syncTree(hid, fixed, x, y, 0);
    CFRelease(hid);
}
