/*
 * What this kernel needs of TrustCache/API.h to compile: the private header Xcode 26's SDK has and Xcode 27's has not.
 * Written from its uses in xnu (kern_trustcache.c, amfi.h, pmap_cs.h), not Apple's file: the layouts are placeholders.
 * The kernel only passes these through AMFI's TrustCache interface, and the built-in AMFI leaves that at version 0.
 */
#ifndef _SWEET_TRUSTCACHE_API_H_
#define _SWEET_TRUSTCACHE_API_H_
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define kTCEntryHashSize 20
#define kUUIDSize 16

typedef uint8_t TCType_t;
enum {
	kTCTypeLTRS = 0, kTCTypeDTRS, kTCTypeStatic, kTCTypeEngineering, kTCTypeLegacy, kTCTypeCryptex, kTCTypeCryptex1BootOS,
	kTCTypeCryptex1BootApp, kTCTypeCryptex1SafariDownlevel, kTCTypeCryptex1Generic, kTCTypeCryptex1Generic_Supplemental,
	kTCTypeCryptex1Generic_Supplemental2, kTCTypeTotal, kTCTypeInvalid = 0xff
};
/* who may load each type: nobody here, there are no trust caches */
static const struct { const char *entitlementValue; } TCTypeConfig[kTCTypeTotal] = {
	[0 ... kTCTypeTotal - 1] = { "sweet.no-trust-caches" },
};
typedef uint8_t TCQueryType_t;
enum { kTCQueryTypeTrustCache = 0, kTCQueryTypeLoadable, kTCQueryTypeStatic, kTCQueryTypeEngineering, kTCQueryTypeAll, kTCQueryTypeTotal };
typedef uint32_t TCCapabilities_t;
enum { kTCCapabilityNone = 0, kTCCapabilityHashType = 1, kTCCapabilityFlags = 2, kTCCapabilityConstraintCategory = 4 };
enum { kTCReturnSuccess = 0, kTCReturnError = 1, kTCReturnOverflow, kTCReturnNotFound, kTCReturnDuplicate, kTCReturnNotPermitted };
typedef struct {
	union {
		uint32_t rawValue;
		struct {
			uint16_t component;
			uint8_t error;
			uint8_t uniqueError;
		};
	};
} TCReturn_t;

typedef struct { const void *module; size_t moduleSize; uint64_t reserved[6]; } TrustCache_t;
typedef struct { const void *trustCache; const void *trustCacheEntry; } TrustCacheQueryToken_t;
typedef struct { bool allowSecondStaticTC; bool allowEngineeringTC; bool allowLegacyTC; uint64_t reserved[32]; } TrustCacheRuntime_t;
typedef struct { uint64_t reserved[32]; } TrustCacheMutableRuntime_t;

/* The header's own inline: this kernel has no trust caches (its AMFI interface is version 0), so there is nothing to set up */
static inline void
trustCacheInitializeRuntime(TrustCacheRuntime_t *runtime, TrustCacheMutableRuntime_t *mutableRuntime, bool allowSecondStaticTC,
    bool allowEngineeringTC, bool allowLegacyTC, const void *image4RuntimeInstance)
{
	(void)runtime;
	(void)mutableRuntime;
	(void)allowSecondStaticTC;
	(void)allowEngineeringTC;
	(void)allowLegacyTC;
	(void)image4RuntimeInstance;
}
#endif
