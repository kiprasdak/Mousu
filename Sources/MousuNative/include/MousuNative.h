#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct MousuHID MousuHID;
MousuHID * _Nullable MousuHIDCreate(void);
void MousuHIDDestroy(MousuHID * _Nonnull context);
// Move the last successful scan's property client to a separate owner. The
// discovery context retains metadata only and creates a fresh client next scan.
MousuHID * _Nullable MousuHIDTakePropertyContext(MousuHID * _Nonnull context);
// NULL means discovery failed; an empty array is a successful empty inventory.
CFArrayRef _Nullable MousuCopyDevices(MousuHID * _Nonnull context) CF_RETURNS_RETAINED;
bool MousuReadNumber(MousuHID * _Nonnull context, uint64_t registryID,
                     const char * _Nonnull key, int64_t * _Nonnull value);
// Validates the same bounds used by native writes, without accessing a device.
bool MousuNumberIsRestorable(const char * _Nonnull key, int64_t value);
bool MousuWriteNumber(MousuHID * _Nonnull context, uint64_t registryID,
                      const char * _Nonnull key, int64_t value);
bool MousuEventBridgeAvailable(void);
bool MousuRequestAccessibility(void);
typedef struct {
    uint64_t senderID;
    bool hasRawScroll;
    double rawX;
    double rawY;
} MousuEventSource;
MousuEventSource MousuGetEventSource(CGEventRef _Nonnull event);
void MousuSyncScroll(CGEventRef _Nonnull event, bool fixed,
                     double x, double y);
