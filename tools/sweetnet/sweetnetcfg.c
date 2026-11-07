/*
 * sweetnetcfg: publish the USB Ethernet (ue0) IPv4 + DNS state into
 * configd's dynamic store so IPMonitor makes it the primary service:
 * default route via the Mac and the DNS resolver configuration.
 *
 * configd sees ue0 (patch 0110) but its IPConfiguration agent never
 * configures it, so no State:/Network/Service/<id>/IPv4 exists and
 * IPMonitor deletes the default route and publishes no DNS. This writes
 * the keys IPConfiguration would have written. Run as root:
 *   sweetnetcfg            publish (and keep the session open with -w)
 *   sweetnetcfg -d         remove the keys
 * Other interfaces (rmnet0, the IPA's cellular data, xnu 3073): -i IFNAME -a ADDR -m MASK -r ROUTER -n DNS[,DNS2]
 * -s ID (the service's last hex digits, so two services can coexist) -p RANK (PrimaryRank: First, Last, Never, Scoped).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

#define SERVICE "5EE7C0DE-0000-4000-8000-0000000000E0"

/*
 * The iOS SDK marks the SCDynamicStore API unavailable, but iOS's
 * SystemConfiguration.framework exports it (configd's own clients use it):
 * resolve it at run time. Keys are the plain schema strings.
 */
typedef const struct __SCDynamicStore *SCDynamicStoreRef;
static SCDynamicStoreRef (*SCDynamicStoreCreate)(CFAllocatorRef, CFStringRef, void *, void *);
static Boolean (*SCDynamicStoreSetValue)(SCDynamicStoreRef, CFStringRef, CFPropertyListRef);
static Boolean (*SCDynamicStoreRemoveValue)(SCDynamicStoreRef, CFStringRef);
static int (*SCError)(void);
static const char *(*SCErrorString)(int);
#define kSCPropNetIPv4Addresses         CFSTR("Addresses")
#define kSCPropNetIPv4SubnetMasks       CFSTR("SubnetMasks")
#define kSCPropNetIPv4Router            CFSTR("Router")
#define kSCPropInterfaceName            CFSTR("InterfaceName")
#define kSCPropNetDNSServerAddresses    CFSTR("ServerAddresses")

static int
sc_load(void)
{
	void *h = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW);
	if (h == NULL) {
		fprintf(stderr, "sweetnetcfg: dlopen: %s\n", dlerror());
		return -1;
	}
	SCDynamicStoreCreate = dlsym(h, "SCDynamicStoreCreate");
	SCDynamicStoreSetValue = dlsym(h, "SCDynamicStoreSetValue");
	SCDynamicStoreRemoveValue = dlsym(h, "SCDynamicStoreRemoveValue");
	SCError = dlsym(h, "SCError");
	SCErrorString = dlsym(h, "SCErrorString");
	if (!SCDynamicStoreCreate || !SCDynamicStoreSetValue || !SCDynamicStoreRemoveValue ||
	    !SCError || !SCErrorString) {
		fprintf(stderr, "sweetnetcfg: SCDynamicStore symbols missing\n");
		return -1;
	}
	return 0;
}

static CFArrayRef
arr1(const char *s)
{
	CFStringRef v = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
	CFArrayRef a = CFArrayCreate(NULL, (const void **)&v, 1, &kCFTypeArrayCallBacks);
	CFRelease(v);
	return a;
}

static void
set(CFMutableDictionaryRef d, CFStringRef k, CFTypeRef v)
{
	CFDictionarySetValue(d, k, v);
	CFRelease(v);
}

int
main(int argc, char **argv)
{
	const char *ifn = "ue0", *addr = "192.168.7.2", *mask = "255.255.255.0", *router = "192.168.7.1";
	const char *dnsarg = "1.1.1.1,8.8.8.8", *id = "E0", *rank = NULL;
	int del = 0, wait = 0, c;
	while ((c = getopt(argc, argv, "dwi:a:m:r:n:s:p:")) != -1) {
		switch (c) {
		case 'd': del = 1; break;
		case 'w': wait = 1; break;
		case 'i': ifn = optarg; break;
		case 'a': addr = optarg; break;
		case 'm': mask = optarg; break;
		case 'r': router = optarg; break;
		case 'n': dnsarg = optarg; break;
		case 's': id = optarg; break;
		case 'p': rank = optarg; break;
		default:
			fprintf(stderr, "usage: sweetnetcfg [-d] [-w] [-i IF -a ADDR -m MASK -r ROUTER -n DNS[,DNS] -s ID -p RANK]\n");
			return 2;
		}
	}
	if (sc_load() != 0) {
		return 1;
	}
	SCDynamicStoreRef st = SCDynamicStoreCreate(NULL, CFSTR("sweetnetcfg"), NULL, NULL);
	if (st == NULL) {
		fprintf(stderr, "sweetnetcfg: SCDynamicStoreCreate: %s\n", SCErrorString(SCError()));
		return 1;
	}
	char service[64];
	snprintf(service, sizeof(service), "5EE7C0DE-0000-4000-8000-0000000000%.2s", id);
	CFStringRef ksvc = CFStringCreateWithFormat(NULL, NULL, CFSTR("State:/Network/Service/%s"), service);
	CFStringRef kv4 = CFStringCreateWithFormat(NULL, NULL, CFSTR("State:/Network/Service/%s/IPv4"), service);
	CFStringRef kdns = CFStringCreateWithFormat(NULL, NULL, CFSTR("State:/Network/Service/%s/DNS"), service);
	CFStringRef cfif = CFStringCreateWithCString(NULL, ifn, kCFStringEncodingUTF8);
	if (del) {
		SCDynamicStoreRemoveValue(st, kv4);
		SCDynamicStoreRemoveValue(st, kdns);
		SCDynamicStoreRemoveValue(st, ksvc);
		printf("sweetnetcfg: removed\n");
		return 0;
	}

	CFMutableDictionaryRef v4 = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	set(v4, kSCPropNetIPv4Addresses, arr1(addr));
	set(v4, kSCPropNetIPv4SubnetMasks, arr1(mask));
	set(v4, kSCPropNetIPv4Router, CFStringCreateWithCString(NULL, router, kCFStringEncodingUTF8));
	CFDictionarySetValue(v4, kSCPropInterfaceName, cfif);

	CFMutableDictionaryRef dns = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFStringRef servers[4];
	int ns = 0;
	char dnsbuf[128];
	snprintf(dnsbuf, sizeof(dnsbuf), "%s", dnsarg);
	for (char *t = strtok(dnsbuf, ","); t && ns < 4; t = strtok(NULL, ",")) {
		servers[ns++] = CFStringCreateWithCString(NULL, t, kCFStringEncodingUTF8);
	}
	set(dns, kSCPropNetDNSServerAddresses,
	    CFArrayCreate(NULL, (const void **)servers, ns, &kCFTypeArrayCallBacks));
	for (int k = 0; k < ns; k++) {
		CFRelease(servers[k]);
	}

	CFMutableDictionaryRef svc = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(svc, kSCPropInterfaceName, cfif);
	if (rank) {
		set(svc, CFSTR("PrimaryRank"), CFStringCreateWithCString(NULL, rank, kCFStringEncodingUTF8));
	}

	Boolean ok = SCDynamicStoreSetValue(st, ksvc, svc) &&
	    SCDynamicStoreSetValue(st, kv4, v4) &&
	    SCDynamicStoreSetValue(st, kdns, dns);
	printf("sweetnetcfg: %s %s (%s)\n", ok ? "published" : "FAILED", ifn, ok ? (rank ? rank : "default rank") :
	    SCErrorString(SCError()));
	CFRelease(v4);
	CFRelease(dns);
	CFRelease(svc);
	if (ok && wait) {
		/* Session keys live as long as the session: keep it open. */
		for (;;) {
			pause();
		}
	}
	return ok ? 0 : 1;
}
