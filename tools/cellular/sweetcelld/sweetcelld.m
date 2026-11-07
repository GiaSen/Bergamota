/*
 * sweetcelld: CommCenter's place on the Xiaomi Mi 8 (Bergamota, iOS 26.6.2), so that iOS's own Cellular Data switch
 * drives the modem's data session through the IPA (xnu 3073: kern.sweet_ipa stages, rmnet0).
 *
 * Derived from IOS-26-Hot's phone/cellular/cellulard.m (github.com/nithinyadavamaraboina-online/IOS-26-Hot, MIT,
 * Copyright (c) 2026 dipa-studio; the licence in LICENSE.IOS-26-Hot next to this file), which serves, in place of
 * CommCenter:
 *   1. SystemStatus (STTelephonyStatusDomainPublisher) -> the status bar's bars, carrier and LTE
 *   2. com.apple.commcenter.coretelephony.xpc (NSXPCListener, CTXPCServiceInterface) -> Settings -> Cellular
 *   3. com.apple.commcenter.xpc (CTServerConnection) -> SpringBoard, systemstatusd
 * Changed here: QMI through the kernel's pass-through (kern.sweet_qmi, qmi_cellular.c) instead of a QRTR socket;
 * CallKit, voice and the control socket left out (no calls yet: the capabilities say so); a data controller of our own:
 * the Cellular Data and Data Roaming switches (persisted in /private/var/sweetcell/settings) start and stop the data
 * session (IPA stages, DPM/WDA/WDS, rmnet0's address, a configd service for rmnet0 below Wi-Fi); logs keep the
 * operator, the country code and the addresses out. A switch change is pushed to CoreTelephony's clients
 * (dataSettingsChanged:, which Settings' data cache waits for); airplane mode is followed through RadiosPreferences (the
 * modem to low power and back); MobileGestalt's cellular-data override (Settings' Cellular pane) is put back whenever
 * its cache is rewritten. /private/var/sweetcell/debug (present at start): Settings' CTServerConnection requests logged.
 *
 * PRIVACY: Never requests, stores, logs, or returns IMEI, IMEISV, IMSI, ICCID,
 * or subscriber phone numbers (MSISDN).
 */
#import <Foundation/Foundation.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>

#include "qmi_cellular.h"

#define SWEETCELL_DIR		"/private/var/sweetcell"
#define CELLULARD_LOG		SWEETCELL_DIR "/sweetcelld.log"
#define CELLULARD_STAMP		SWEETCELL_DIR "/sweetcelld.boot"
#define CELLULARD_CONF		SWEETCELL_DIR "/sweetcelld.conf"
#define SWEETCELL_SETTINGS	SWEETCELL_DIR "/settings"
#define SWEETCELL_HANDLE	SWEETCELL_DIR "/wds-handle"
#define SWEET_DATA_SERVICE	"5EE7C0DE-0000-4000-8000-0000000000C1"
#define RADIOS_PLIST		"/private/var/preferences/SystemConfiguration/com.apple.radios.plist"
#define SLOT1_UUID_STR		"00000001-0000-4000-8000-000000000001"

/* ---- Typed SPI interfaces (resolved dynamically via NSClassFromString) ---- */

@interface HotXPCInterfaceSPI : NSObject
+ (instancetype)interfaceWithProtocol:(Protocol *)protocol;
- (void)setClasses:(NSSet<Class> *)classes forSelector:(SEL)sel
     argumentIndex:(NSUInteger)arg ofReply:(BOOL)ofReply;
@end

@interface HotXPCConnectionSPI : NSObject
@property (nonatomic, strong) id exportedInterface;
@property (nonatomic, strong) id exportedObject;
@property (nonatomic, strong) id remoteObjectInterface;
@property (nonatomic, copy) void (^invalidationHandler)(void);
@property (nonatomic, copy) void (^interruptionHandler)(void);
@property (nonatomic, readonly) int processIdentifier;
- (id)remoteObjectProxyWithErrorHandler:(void (^)(NSError *error))handler;
- (void)resume;
- (void)invalidate;
@end

@interface HotXPCListenerSPI : NSObject
@property (nonatomic, weak) id delegate;
- (instancetype)initWithMachServiceName:(NSString *)name;
- (void)resume;
@end

/* SystemStatus private classes */
@interface HotSTMutableSIMInfo : NSObject
- (void)setSIMPresent:(BOOL)v;
- (void)setBootstrap:(BOOL)v;
- (void)setLabel:(NSString *)v;
- (void)setShortLabel:(NSString *)v;
- (void)setSignalStrengthBars:(NSUInteger)v;
- (void)setMaxSignalStrengthBars:(NSUInteger)v;
- (void)setServiceState:(NSUInteger)v;
- (void)setCellularServiceState:(NSUInteger)v;
- (void)setServiceDescription:(NSString *)v;
- (void)setSecondaryServiceDescription:(NSString *)v;
- (void)setDataNetworkType:(NSUInteger)v;
- (void)setProvidingDataConnection:(BOOL)v;
- (void)setPreferredForDataConnections:(BOOL)v;
- (void)setRegisteredWithoutCellular:(BOOL)v;
- (void)setCallForwardingEnabled:(BOOL)v;
@end

@interface HotSTMutableTelephonyData : NSObject
- (void)setCellularRadioCapabilityEnabled:(BOOL)v;
- (void)setDualSIMEnabled:(BOOL)v;
- (void)setRadioModuleDead:(BOOL)v;
- (void)setInactiveSOSEnabled:(BOOL)v;
- (void)setUsingStewieForSOS:(BOOL)v;
- (void)setUsingStewieConnection:(BOOL)v;
- (void)updateSIMOneInfoWithBlock:(void (^)(HotSTMutableSIMInfo *sim))block;
- (void)updateSIMTwoInfoWithBlock:(void (^)(HotSTMutableSIMInfo *sim))block;
@end

@interface HotSTTelephonyPublisher : NSObject
- (void)updateDataWithBlock:(void (^)(HotSTMutableTelephonyData *data))block;
@end

/* CoreTelephony private constructors & delegate notification methods */
@interface HotCTContextInfo : NSObject
+ (instancetype)contextWithUUID:(NSUUID *)uuid andAccountID:(NSString *)acct andSlot:(NSInteger)slot;
@end

@interface HotCTServiceDescriptor : NSObject
+ (instancetype)telephonyDescriptorWithInstance:(NSNumber *)inst;
@end

@interface HotCTServiceDescriptorContainer : NSObject
- (instancetype)initWithDescriptors:(NSArray *)descs;
@end

@interface HotCTSimLabel : NSObject
- (instancetype)initWithId:(NSString *)uid andText:(NSString *)text andDidSetup:(BOOL)setup;
@end

@interface HotCTSimHardwareInfo : NSObject
- (instancetype)initWithHardwareInfo:(NSInteger)hwType simLocation:(NSInteger)loc;
@end

@interface HotCTDisplayPlanList : NSObject
- (instancetype)initWithDisplayPlans:(NSArray *)plans;
@end

@interface HotCTSupportedMaxDataRates : NSObject
- (instancetype)initWithRates:(NSArray *)rates;
@end

@interface HotCTEncryptionStatusInfo : NSObject
- (instancetype)initWithStatus:(NSInteger)st;
@end

/* Distinct typed response wrappers so ARC never sees ambiguous initWithResult: */
@interface HotCTBoolResp : NSObject
- (instancetype)initWithResult:(BOOL)r;
@end

@interface HotCTObjResp : NSObject
- (instancetype)initWithResult:(id)r;
@end

@interface HotCTEnabledResp : NSObject
- (instancetype)initWithIsEnabled:(BOOL)en;
@end

@interface HotCTInfoResp : NSObject
- (instancetype)initWithInfo:(id)info;
@end

@interface HotCTStatusResp : NSObject
- (instancetype)initWithStatus:(id)st;
@end

@interface HotCTSigInfoResp : NSObject
- (instancetype)initWithSignalStrengthInfo:(id)info;
@end

@interface HotCTSigMeasResp : NSObject
- (instancetype)initWithSignalStrengthMeasurements:(id)m;
@end

@interface HotCTOpNameResp : NSObject
- (instancetype)initWithOperatorName:(NSString *)name;
@end

@interface HotCTRoamingResp : NSObject
- (instancetype)initWithRoamingStatus:(id)st;
@end

@interface HotCTCurRatResp : NSObject
- (instancetype)initWithRat:(NSString *)rat;
@end

@interface HotCTRegRatResp : NSObject
- (instancetype)initWithRAT:(NSString *)rat;
@end

@interface HotCTTechResp : NSObject
- (instancetype)initWithTechnology:(NSString *)tech;
@end

@interface HotCTRatSelResp : NSObject
- (instancetype)initWithRATSelection:(id)sel;
@end

@interface HotCTDataAttResp : NSObject
- (instancetype)initWithIsDataAttached:(BOOL)att;
@end

@interface HotCTHomeResp : NSObject
- (instancetype)initWithIsHome:(BOOL)home;
@end

@interface HotCTAvailResp : NSObject
- (instancetype)initWithIsAvailable:(BOOL)avail;
@end

@interface HotCTReselResp : NSObject
- (instancetype)initWithNeedsReselection:(BOOL)need;
@end

@interface HotCTMccResp : NSObject
- (instancetype)initWithMcc:(NSString *)mcc;
@end

@interface HotCTLastMccResp : NSObject
- (instancetype)initWithLastMcc:(NSString *)mcc;
@end

@interface HotCTMncResp : NSObject
- (instancetype)initWithMnc:(NSString *)mnc;
@end

@interface HotCTPlmnResp : NSObject
- (instancetype)initWithPlmn:(NSString *)plmn;
@end

@interface HotCTLabelResp : NSObject
- (instancetype)initWithLabel:(id)lbl;
@end

@interface HotCTHwResp : NSObject
- (instancetype)initWithHardwareInfo:(id)hw;
@end

@interface HotCTNRResp : NSObject
- (instancetype)initWithNRStatus:(id)nr;
@end

@interface HotCTSupportResp : NSObject
- (instancetype)initWithSupport:(BOOL)sup;
@end

@interface HotCTDataRateResp : NSObject
- (instancetype)initWithDataRate:(NSInteger)rate;
@end

@interface HotCTSupRatesResp : NSObject
- (instancetype)initWithSupportedRates:(id)rates;
@end

@interface HotCTBandResp : NSObject
- (instancetype)initWithBandInfo:(id)bi;
@end

@interface HotCTCtxResp : NSObject
- (instancetype)initWithContext:(id)ctx;
@end

@interface HotCTNetSelInfoResp : NSObject
- (instancetype)initWithNetworkSelectionInfo:(id)info;
@end

@interface HotCTNetResp : NSObject
- (instancetype)initWithNetwork:(id)net;
@end

@interface HotCTNetListResp : NSObject
- (instancetype)initWithNetworkList:(id)list;
@end

@interface HotCTIMSResp : NSObject
- (instancetype)initWithIMSRegistrationStatus:(id)ims;
@end

@interface HotCTIMSTransResp : NSObject
- (instancetype)initWithIMSRegistrationInfo:(id)ims;
@end

@interface HotCTEncResp : NSObject
- (instancetype)initWithEncryptionStatusInfo:(id)enc;
@end

@interface HotCTCauseResp : NSObject
- (instancetype)initWithCauseCode:(NSNumber *)cc;
@end

@interface HotCTPlanListResp : NSObject
- (instancetype)initWithPlanList:(id)list;
@end

@interface HotCTListResp : NSObject
- (instancetype)initWithList:(id)list;
@end

@interface HotCTDevsResp : NSObject
- (instancetype)initWithDevices:(id)devs;
@end

@interface HotCTTransferPlansResp : NSObject
- (instancetype)initWithRemtoeDevices:(id)devs isFlexPolicyOn:(BOOL)flex;
@end

@interface HotCTMeInfoResp : NSObject
- (instancetype)initWithEquipmentInfoList:(id)list;
@end

@interface HotCTFwInfoResp : NSObject
- (instancetype)initWithFimwareUpdateInfo:(id)dict;
@end

@interface HotCTCallCapResp : NSObject
- (instancetype)initWithCapabilities:(id)caps;
@end

/* CallKit dynamic SPI interfaces (loaded via dlopen, zero build-time framework link needed) */
@interface HotCXHandleSPI : NSObject
- (instancetype)initWithType:(NSInteger)type value:(NSString *)value;
@end

@interface HotCXAccountSPI : NSObject
- (instancetype)initWithUUID:(NSUUID *)UUID
		 description:(NSString *)description
		 serviceName:(NSString *)serviceName
	      isoCountryCode:(NSString *)isoCountryCode
		      handle:(id)handle
		  shortLabel:(NSString *)shortLabel;
@end

@interface HotCXSenderIdentitySPI : NSObject
- (instancetype)initWithUUID:(NSUUID *)UUID account:(id)account;
- (instancetype)initWithUUID:(NSUUID *)UUID handle:(id)handle localizedName:(NSString *)localizedName;
@end

@interface HotCXProviderConfigSPI : NSObject
- (instancetype)initWithLocalizedName:(NSString *)localizedName;
- (void)setLocalizedName:(NSString *)localizedName;
- (void)setSupportedHandleTypes:(NSSet *)types;
- (void)setSupportsAudioOnly:(BOOL)v;
- (void)setSupportsVideo:(BOOL)v;
- (void)setSupportsEmergency:(BOOL)v;
- (void)setSupportsVoicemail:(BOOL)v;
- (void)setSupportsCurrentPlatform:(BOOL)v;
- (void)setSupportsRinging:(BOOL)v;
- (void)setSupportsDynamicSystemUI:(BOOL)v;
- (void)setSupportsAudioTranslation:(BOOL)v;
- (void)setIncludesCallsInRecents:(BOOL)v;
- (void)setMaximumCallGroups:(NSUInteger)v;
- (void)setMaximumCallsPerCallGroup:(NSUInteger)v;
- (void)setPrioritizedSenderIdentities:(NSOrderedSet *)identities;
- (void)setSenderIdentities:(NSSet *)identities;
- (void)setEmergencyHandles:(NSArray *)handles;
@end

@interface HotCXProviderSPI : NSObject
- (instancetype)initWithConfiguration:(id)configuration;
- (id)configuration;
- (void)setConfiguration:(id)configuration;
- (void)setDelegate:(id)delegate queue:(dispatch_queue_t)queue;
- (void)reportNewIncomingCallWithUUID:(NSUUID *)UUID
			       update:(id)update
			   completion:(void (^)(NSError *error))completion;
- (void)reportCallWithUUID:(NSUUID *)UUID updated:(id)update;
- (void)reportOutgoingCallWithUUID:(NSUUID *)UUID sentInvitationAtDate:(NSDate *)dateSentInvitation;
- (void)reportOutgoingCallWithUUID:(NSUUID *)UUID startedConnectingAtDate:(NSDate *)dateStartedConnecting;
- (void)reportOutgoingCallWithUUID:(NSUUID *)UUID connectedAtDate:(NSDate *)dateConnected;
- (void)reportCallWithUUID:(NSUUID *)UUID endedAtDate:(NSDate *)dateEnded reason:(NSInteger)endedReason;
- (void)reportCallWithUUID:(NSUUID *)UUID endedAtDate:(NSDate *)dateEnded privateReason:(NSInteger)privateReason;
@end

@interface HotCXActionSPI : NSObject
- (NSUUID *)callUUID;
- (void)fulfill;
- (void)fail;
@end

/* Client delegate push interface */
@interface HotCTDelegateProxy : NSObject
- (void)subscriptionInfoDidChange;
- (void)activeSubscriptionsDidChange;
- (void)simStatusDidChange:(id)ctx status:(NSString *)status;
- (void)signalStrengthChanged:(id)ctx info:(id)info;
- (void)operatorNameChanged:(id)ctx name:(NSString *)name;
- (void)displayStatusChanged:(id)ctx status:(id)status;
- (void)dataStatus:(id)ctx dataStatusInfo:(id)dataStatus;
- (void)servingNetworkChanged:(id)ctx;
/* (sweetcelld) CoreTelephonyClientDataDelegateInternal: Settings' PSUICoreTelephonyDataCache reads the Cellular Data
 * switch once (_CTServerConnectionGetCellularDataIsEnabled), keeps it, and only takes a new value from these */
- (void)dataSettingsChanged:(id)settings;
- (void)dataRoamingSettingsChanged:(id)ctx status:(BOOL)status;
@end

/* ---- Logging & runtime C symbol resolution (libxpc + notify + blocks) ---- */

static FILE *g_logf;
static os_unfair_lock g_state_lock = OS_UNFAIR_LOCK_INIT;
static struct cellular_state g_state;
static bool g_cellular_data_enabled = true;
static bool g_data_roaming = true;      /* Settings > Cellular > Cellular Data Options > Data Roaming */
static bool g_no_xpc;                   /* --no-xpc: next to CommCenter, for tests (no listeners, no status publisher) */
static bool g_debug_log;                /* /private/var/sweetcell/debug exists: log Settings' CTServerConnection packet requests */
static bool g_airplane_mode = false;
static bool g_enable_wds_data = false;
static bool g_publish_system_status = true;
static uint16_t g_rat_mode_pref = 0x001cu; /* GSM|WCDMA|LTE */
static char g_configured_apn[64] = "";

typedef void *hot_xpc_t;
static hot_xpc_t (*fn_xpc_conn_create_mach)(const char *, dispatch_queue_t, uint64_t);
static void (*fn_xpc_conn_set_target_queue)(hot_xpc_t, dispatch_queue_t);
static void (*fn_xpc_conn_set_handler)(hot_xpc_t, void (^)(hot_xpc_t));
static void (*fn_xpc_conn_resume)(hot_xpc_t);
static void (*fn_xpc_conn_send)(hot_xpc_t, hot_xpc_t);
static hot_xpc_t (*fn_xpc_dict_create)(const char * const *, const hot_xpc_t *, size_t);
static hot_xpc_t (*fn_xpc_dict_create_reply)(hot_xpc_t);
static void (*fn_xpc_dict_set_int64)(hot_xpc_t, const char *, int64_t);
static void (*fn_xpc_dict_set_string)(hot_xpc_t, const char *, const char *);
static void (*fn_xpc_dict_set_bool)(hot_xpc_t, const char *, bool);
static void (*fn_xpc_dict_set_value)(hot_xpc_t, const char *, hot_xpc_t);
static const char *(*fn_xpc_dict_get_string)(hot_xpc_t, const char *);
static hot_xpc_t (*fn_xpc_dict_get_value)(hot_xpc_t, const char *);
static const void *(*fn_xpc_get_type)(hot_xpc_t);
static hot_xpc_t (*fn_xpc_retain)(hot_xpc_t);
static void (*fn_xpc_release)(hot_xpc_t);
static const void *sym_xpc_type_connection;
static const void *sym_xpc_type_dictionary;
static const void *sym_xpc_error_conn_invalid;
static uint32_t (*fn_notify_post)(const char *);
static const char *(*fn_Block_signature)(void *);

static void clog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void clog(const char *fmt, ...)
{
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	struct tm tm;
	localtime_r(&ts.tv_sec, &tm);

	char msg[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);

	FILE *out = g_logf ? g_logf : stderr;
	fprintf(out, "%02d:%02d:%02d.%03ld [sweetcelld] %s\n",
		tm.tm_hour, tm.tm_min, tm.tm_sec, ts.tv_nsec / 1000000, msg);
	fflush(out);
}

static void resolve_runtime_symbols(void)
{
	fn_xpc_conn_create_mach = dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
	fn_xpc_conn_set_target_queue = dlsym(RTLD_DEFAULT, "xpc_connection_set_target_queue");
	fn_xpc_conn_set_handler = dlsym(RTLD_DEFAULT, "xpc_connection_set_event_handler");
	fn_xpc_conn_resume = dlsym(RTLD_DEFAULT, "xpc_connection_resume");
	fn_xpc_conn_send = dlsym(RTLD_DEFAULT, "xpc_connection_send_message");
	fn_xpc_dict_create = dlsym(RTLD_DEFAULT, "xpc_dictionary_create");
	fn_xpc_dict_create_reply = dlsym(RTLD_DEFAULT, "xpc_dictionary_create_reply");
	fn_xpc_dict_set_int64 = dlsym(RTLD_DEFAULT, "xpc_dictionary_set_int64");
	fn_xpc_dict_set_string = dlsym(RTLD_DEFAULT, "xpc_dictionary_set_string");
	fn_xpc_dict_set_bool = dlsym(RTLD_DEFAULT, "xpc_dictionary_set_bool");
	fn_xpc_dict_set_value = dlsym(RTLD_DEFAULT, "xpc_dictionary_set_value");
	fn_xpc_dict_get_string = dlsym(RTLD_DEFAULT, "xpc_dictionary_get_string");
	fn_xpc_dict_get_value = dlsym(RTLD_DEFAULT, "xpc_dictionary_get_value");
	fn_xpc_get_type = dlsym(RTLD_DEFAULT, "xpc_get_type");
	fn_xpc_retain = dlsym(RTLD_DEFAULT, "xpc_retain");
	fn_xpc_release = dlsym(RTLD_DEFAULT, "xpc_release");
	sym_xpc_type_connection = dlsym(RTLD_DEFAULT, "_xpc_type_connection");
	sym_xpc_type_dictionary = dlsym(RTLD_DEFAULT, "_xpc_type_dictionary");
	sym_xpc_error_conn_invalid = dlsym(RTLD_DEFAULT, "_xpc_error_connection_invalid");
	fn_notify_post = dlsym(RTLD_DEFAULT, "notify_post");
	fn_Block_signature = dlsym(RTLD_DEFAULT, "_Block_signature");
}

static void load_config(void)
{
	/* Check iOS AirplaneMode preference first */
	NSDictionary *radios = [NSDictionary dictionaryWithContentsOfFile:@RADIOS_PLIST];
	if ([radios isKindOfClass:[NSDictionary class]]) {
		NSNumber *ap = radios[@"AirplaneMode"];
		if ([ap respondsToSelector:@selector(boolValue)])
			g_airplane_mode = [ap boolValue];
	}

	FILE *f = fopen(CELLULARD_CONF, "r");
	if (!f)
		return;
	char line[160];
	while (fgets(line, sizeof(line), f)) {
		line[strcspn(line, "\r\n")] = '\0';
		if (!strncmp(line, "enable_data=", 12))
			g_enable_wds_data = (atoi(line + 12) != 0);
		else if (!strncmp(line, "cellular_data=", 14))
			g_cellular_data_enabled = (atoi(line + 14) != 0);
		else if (!strncmp(line, "airplane_mode=", 14))
			g_airplane_mode = (atoi(line + 14) != 0);
		else if (!strncmp(line, "publish_system_status=", 22))
			g_publish_system_status = (atoi(line + 22) != 0);
		else if (!strncmp(line, "apn=", 4))
			snprintf(g_configured_apn, sizeof(g_configured_apn), "%s", line + 4);
		else if (!strncmp(line, "rat_mode=", 9)) {
			const char *rm = line + 9;
			if (!strcmp(rm, "3g2g") || !strcmp(rm, "cs"))
				g_rat_mode_pref = 0x000cu; /* GSM|WCDMA */
			else if (!strcmp(rm, "gsm") || !strcmp(rm, "2g"))
				g_rat_mode_pref = 0x0004u; /* GSM */
			else if (!strcmp(rm, "wcdma") || !strcmp(rm, "3g"))
				g_rat_mode_pref = 0x0008u; /* WCDMA */
			else if (!strcmp(rm, "lte") || !strcmp(rm, "4g"))
				g_rat_mode_pref = 0x0010u; /* LTE */
			else
				g_rat_mode_pref = 0x001cu; /* GSM|WCDMA|LTE */
		}
	}
	fclose(f);
}

static struct cellular_state snapshot_state(void)
{
	os_unfair_lock_lock(&g_state_lock);
	struct cellular_state cp = g_state;
	os_unfair_lock_unlock(&g_state_lock);
	return cp;
}

static void ct_set(id obj, NSString *key, id val)
{
	if (!obj || !key)
		return;
	@try {
		[obj setValue:val forKey:key];
	} @catch (id exc) {
		(void)exc;
	}
}

static id ct_get(id obj, NSString *key)
{
	if (!obj || !key)
		return nil;
	@try {
		return [obj valueForKey:key];
	} @catch (id exc) {
		return nil;
	}
}

static void wipe_ram(void *p, size_t n)
{
	volatile uint8_t *vp = (volatile uint8_t *)p;
	while (n--)
		*vp++ = 0;
}

static bool is_emergency_cstr(const char *s)
{
	if (!s || !s[0])
		return false;
	char digits[24];
	size_t o = 0;
	wipe_ram(digits, sizeof(digits));
	for (size_t i = 0; s[i] && o + 1 < sizeof(digits); i++) {
		if ((s[i] >= '0' && s[i] <= '9') || s[i] == '+' || s[i] == '*' || s[i] == '#')
			digits[o++] = s[i];
	}
	bool m = (!strcmp(digits, "112") || !strcmp(digits, "911") || !strcmp(digits, "100") ||
		  !strcmp(digits, "101") || !strcmp(digits, "102") || !strcmp(digits, "108") ||
		  !strcmp(digits, "999") || !strcmp(digits, "000"));
	wipe_ram(digits, sizeof(digits));
	return m;
}

/* ---- CoreTelephony Model Object Builders ---- */

static NSUUID *slot1_uuid(void)
{
	static NSUUID *u;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		u = [[NSUUID alloc] initWithUUIDString:@SLOT1_UUID_STR];
	});
	return u;
}

static id build_slot1_context(const struct cellular_state *st)
{
	Class cls = NSClassFromString(@"CTXPCServiceSubscriptionContext");
	if (!cls)
		return nil;
	id ctx = [[cls alloc] init];
	BOOL good = st->sim_present && (strcmp(st->sim_state, "present") == 0);
	ct_set(ctx, @"slotID", @(1));
	ct_set(ctx, @"uuid", slot1_uuid());
	ct_set(ctx, @"labelID", @SLOT1_UUID_STR);
	ct_set(ctx, @"label", @"Primary");
	ct_set(ctx, @"phoneNumber", @"");
	ct_set(ctx, @"isSimPresent", @(st->sim_present));
	ct_set(ctx, @"isSimGood", @(good));
	ct_set(ctx, @"isSimHidden", @(NO));
	ct_set(ctx, @"isSimDataOnly", @(NO));
	ct_set(ctx, @"userDataPreferred", @(1));
	ct_set(ctx, @"userDefaultVoice", @(1));
	return ctx;
}

static id build_subscription_info(const struct cellular_state *st)
{
	Class cls = NSClassFromString(@"CTXPCServiceSubscriptionInfo");
	if (!cls)
		return nil;
	id info = [[cls alloc] init];
	id ctx1 = build_slot1_context(st);
	NSArray *all = ctx1 ? @[ctx1] : @[];
	NSArray *active = (ctx1 && st->sim_present) ? @[ctx1] : @[];
	ct_set(info, @"subscriptions", all);
	ct_set(info, @"subscriptionsInUse", active);
	ct_set(info, @"subscriptionsValid", active);
	return info;
}

static id build_active_contexts(const struct cellular_state *st)
{
	Class cls = NSClassFromString(@"CTXPCContexts");
	Class icls = NSClassFromString(@"CTXPCContextInfo");
	if (!cls || !icls)
		return nil;
	id contexts = [[cls alloc] init];
	if (st->sim_present) {
		id ci = [(id)icls contextWithUUID:slot1_uuid()
				     andAccountID:@SLOT1_UUID_STR
					  andSlot:1];
		ct_set(ci, @"label", @"Primary");
		ct_set(ci, @"labelID", @SLOT1_UUID_STR);
		ct_set(ci, @"phoneNumber", @"");
		NSArray *arr = ci ? @[ci] : @[];
		ct_set(contexts, @"subscriptions", arr);
		ct_set(contexts, @"existingUserSubscriptions", arr);
		ct_set(contexts, @"dataPreferred", slot1_uuid());
		ct_set(contexts, @"voicePreferred", slot1_uuid());
	} else {
		ct_set(contexts, @"subscriptions", @[]);
		ct_set(contexts, @"existingUserSubscriptions", @[]);
	}
	return contexts;
}

static id build_slot1_descriptor(void)
{
	Class cls = NSClassFromString(@"CTServiceDescriptor");
	if (!cls)
		return nil;
	return [(id)cls telephonyDescriptorWithInstance:@(1)];
}

static NSString *sim_status_string(const struct cellular_state *st)
{
	if (!st->sim_present)
		return @"kCTSIMSupportSIMStatusNotInserted";
	if (!strcmp(st->sim_state, "pin_locked"))
		return @"kCTSIMSupportSIMStatusPINLocked";
	if (!strcmp(st->sim_state, "puk_locked"))
		return @"kCTSIMSupportSIMStatusPUKLocked";
	if (!strcmp(st->sim_state, "network_locked"))
		return @"kCTSIMSupportSIMStatusNetworkLocked";
	if (!strcmp(st->app_state, "ready") || !strcmp(st->app_state, "subscription_ready"))
		return @"kCTSIMSupportSIMStatusReady";
	return @"kCTSIMSupportSIMStatusInserted";
}

static BOOL is_radio_off(const struct cellular_state *st)
{
	if (g_airplane_mode)
		return YES;
	if (st->dms_mode_raw == 0)
		return NO;
	if (st->dms_mode_raw == 0xff && st->reg_state_raw == 1)
		return NO;
	if (st->dms_mode_raw != 0xff)
		return YES;
	return NO;
}

static NSString *reg_status_string(const struct cellular_state *st)
{
	if (!st->sim_present || is_radio_off(st))
		return @"kCTRegistrationStatusNotRegistered";
	switch (st->reg_state_raw) {
	case 1:
		return st->roaming ? @"kCTRegistrationStatusRegisteredRoaming"
				   : @"kCTRegistrationStatusRegisteredHome";
	case 2:
		return @"kCTRegistrationStatusSearching";
	case 3:
		return @"kCTRegistrationStatusDenied";
	default:
		return @"kCTRegistrationStatusNotRegistered";
	}
}

static NSString *public_rat_string(const struct cellular_state *st)
{
	if (!strcmp(st->rat, "5g_nr")) return @"CTRadioAccessTechnologyNR";
	if (!strcmp(st->rat, "lte"))   return @"CTRadioAccessTechnologyLTE";
	if (!strcmp(st->rat, "umts"))  return @"CTRadioAccessTechnologyWCDMA";
	if (!strcmp(st->rat, "gsm"))   return @"CTRadioAccessTechnologyEdge";
	return @"";
}

static NSString *reg_rat_string(const struct cellular_state *st)
{
	if (!strcmp(st->rat, "5g_nr")) return @"kCTRegistrationRadioAccessTechnologyNR";
	if (!strcmp(st->rat, "lte"))   return @"kCTRegistrationRadioAccessTechnologyLTE";
	if (!strcmp(st->rat, "umts"))  return @"kCTRegistrationRadioAccessTechnologyUTRAN";
	if (!strcmp(st->rat, "gsm"))   return @"kCTRegistrationRadioAccessTechnologyGSM";
	return @"kCTRegistrationRadioAccessTechnologyUnknown";
}

static id build_signal_info(const struct cellular_state *st)
{
	Class cls = NSClassFromString(@"CTSignalStrengthInfo");
	if (!cls)
		return nil;
	id info = [[cls alloc] init];
	int bars = (st->sim_present && !is_radio_off(st) && st->reg_state_raw == 1) ? st->bars_0_to_4 : 0;
	ct_set(info, @"bars", @(bars));
	ct_set(info, @"displayBars", @(bars));
	ct_set(info, @"maxDisplayBars", @(4));
	return info;
}

static id build_signal_measurements(const struct cellular_state *st)
{
	Class cls = NSClassFromString(@"CTSignalStrengthMeasurements");
	if (!cls)
		return nil;
	id m = [[cls alloc] init];
	if (st->has_rssi) ct_set(m, @"rssi", @(st->rssi_dbm));
	if (st->has_rsrp) ct_set(m, @"rsrp", @(st->rsrp_dbm));
	if (st->has_rsrq) ct_set(m, @"rsrq", @(st->rsrq_db));
	if (st->has_snr)  ct_set(m, @"snr", @(st->snr_tenth_db / 10));
	return m;
}

static id build_display_status(const struct cellular_state *st)
{
	Class cls = NSClassFromString(@"CTRegistrationDisplayStatus");
	if (!cls)
		return nil;
	id ds = [[cls alloc] init];
	ct_set(ds, @"registrationDisplayStatus", reg_status_string(st));
	ct_set(ds, @"isInHomeCountry", @(!st->roaming));
	ct_set(ds, @"changedDueToSimRemoval", @(!st->sim_present));
	ct_set(ds, @"isRegistrationForcedHome", @(NO));
	ct_set(ds, @"isSatelliteSystem", @(NO));
	return ds;
}

static id build_data_status(const struct cellular_state *st)
{
	Class cls = NSClassFromString(@"CTDataStatus");
	if (!cls)
		return nil;
	id ds = [[cls alloc] init];
	BOOL attached = st->sim_present && !is_radio_off(st) && st->reg_state_raw == 1 && st->ps_attached;
	/* CoreTelephony indicator table: 0=none, 2=EDGE, 3=3G, 7=LTE, 11=5G */
	int ind = 0, rtech = 0;
	if (attached) {
		if (!strcmp(st->rat, "5g_nr"))     { ind = 11; rtech = 9; }
		else if (!strcmp(st->rat, "lte"))  { ind = 7;  rtech = 6; }
		else if (!strcmp(st->rat, "umts")) { ind = 3;  rtech = 2; }
		else if (!strcmp(st->rat, "gsm"))  { ind = 2;  rtech = 1; }
	}
	ct_set(ds, @"attached", @(attached));
	ct_set(ds, @"dataSim", @(st->sim_present));
	ct_set(ds, @"roamAllowed", @(YES));
	ct_set(ds, @"cellularDataPossible", @(st->sim_present && g_cellular_data_enabled));
	ct_set(ds, @"inHomeCountry", @(!st->roaming));
	ct_set(ds, @"indicator", @(ind));
	ct_set(ds, @"indicatorOverride", @(0));
	ct_set(ds, @"radioTechnology", @(rtech));
	ct_set(ds, @"activeContexts", @(st->data_connected ? 1 : 0));
	ct_set(ds, @"totalActiveContexts", @(st->data_connected ? 1 : 0));
	return ds;
}

static id build_data_status_basic(const struct cellular_state *st)
{
	Class cls = NSClassFromString(@"CTDataStatusBasic");
	if (!cls)
		return nil;
	id ds = [[cls alloc] init];
	BOOL attached = st->sim_present && !is_radio_off(st) && st->reg_state_raw == 1 && st->ps_attached;
	ct_set(ds, @"attached", @(attached));
	ct_set(ds, @"hasIndicator", @(attached));
	ct_set(ds, @"inHomeCountry", @(!st->roaming));
	ct_set(ds, @"roamAllowed", @(YES));
	ct_set(ds, @"cellularDataPossible", @(st->sim_present && g_cellular_data_enabled));
	ct_set(ds, @"newRadioCoverage", @(strcmp(st->rat, "5g_nr") == 0));
	return ds;
}

/* ---- SystemStatus Publisher (Status Bar Bars + Carrier + LTE) ---- */

static HotSTTelephonyPublisher *g_st_publisher;

static void init_system_status_publisher(void)
{
	if (!g_publish_system_status)
		return;
	@try {
		void *h = dlopen("/System/Library/PrivateFrameworks/SystemStatus.framework/SystemStatus", RTLD_NOW);
		if (!h) {
			clog("SystemStatus dlopen unavailable: %s", dlerror());
			return;
		}
		Class pubCls = NSClassFromString(@"STTelephonyStatusDomainPublisher");
		if (pubCls) {
			g_st_publisher = [[pubCls alloc] init];
			clog("STTelephonyStatusDomainPublisher initialized (%p)", (__bridge void *)g_st_publisher);
		}
	} @catch (id exc) {
		clog("SystemStatus init exception: %s", [[exc description] UTF8String]);
	}
}

static void publish_system_status(const struct cellular_state *st)
{
	if (!g_st_publisher)
		return;
	@try {
		NSString *op = st->operator_name[0] ? [NSString stringWithUTF8String:st->operator_name] : @"Carrier";
		BOOL simPresent = st->sim_present;
		BOOL radioOff = is_radio_off(st);
		NSUInteger bars = (simPresent && !radioOff && st->reg_state_raw == 1)
				  ? (NSUInteger)st->bars_0_to_4 : 0;

		/* STTelephonyStatusDomainServiceState: 0=No Service, 1=Searching, 2=Service, 3=SOS */
		NSUInteger svcState = 0;
		if (simPresent && !radioOff) {
			if (st->reg_state_raw == 1)
				svcState = 2;
			else if (st->dms_mode_raw == 0 && st->reg_state_raw == 2)
				svcState = 1;
			else if (st->reg_state_raw == 2)
				svcState = 1;
		}

		/* STTelephonyStatusDomainDataNetworkType: 0=Unknown, 3=EDGE, 5=HSDPA, 7=LTE, 11=5G */
		NSUInteger netType = 0;
		if (svcState == 2 && st->ps_attached) {
			if (!strcmp(st->rat, "5g_nr"))     netType = 11;
			else if (!strcmp(st->rat, "lte"))  netType = 7;
			else if (!strcmp(st->rat, "umts")) netType = 5;
			else if (!strcmp(st->rat, "gsm"))  netType = 3;
		}

		BOOL qrtrAlive = st->qrtr_connected;
		BOOL psUp = (svcState == 2 && st->ps_attached && g_cellular_data_enabled);

		[g_st_publisher updateDataWithBlock:^(HotSTMutableTelephonyData *data) {
			if (!data)
				return;
			[data setCellularRadioCapabilityEnabled:!radioOff];
			[data setDualSIMEnabled:NO];
			[data setRadioModuleDead:!qrtrAlive];
			[data setInactiveSOSEnabled:NO];
			[data setUsingStewieForSOS:NO];
			[data setUsingStewieConnection:NO];
			[data updateSIMOneInfoWithBlock:^(HotSTMutableSIMInfo *sim) {
				if (!sim)
					return;
				[sim setSIMPresent:simPresent];
				[sim setBootstrap:NO];
				[sim setLabel:@"Primary"];
				[sim setShortLabel:@"P"];
				[sim setMaxSignalStrengthBars:4];
				[sim setSignalStrengthBars:bars];
				[sim setServiceState:svcState];
				[sim setCellularServiceState:svcState];
				[sim setServiceDescription:(svcState == 2 ? op : @"")];
				[sim setSecondaryServiceDescription:@""];
				[sim setDataNetworkType:netType];
				[sim setPreferredForDataConnections:simPresent];
				[sim setProvidingDataConnection:psUp];
				[sim setRegisteredWithoutCellular:NO];
				[sim setCallForwardingEnabled:NO];
			}];
		}];
	} @catch (id exc) {
		clog("SystemStatus publish exception: %s", [[exc description] UTF8String]);
	}
}

/* ---- Recursive Protocol Method Lookup for NSXPCInterface Fallback ---- */

static struct objc_method_description find_proto_method(Protocol *proto, SEL sel, NSMutableSet *visited)
{
	struct objc_method_description empty = { NULL, NULL };
	if (!proto || !sel)
		return empty;
	NSString *pname = [NSString stringWithUTF8String:protocol_getName(proto)];
	if ([visited containsObject:pname])
		return empty;
	[visited addObject:pname];

	struct objc_method_description d = protocol_getMethodDescription(proto, sel, YES, YES);
	if (!d.types)
		d = protocol_getMethodDescription(proto, sel, NO, YES);
	if (d.types)
		return d;

	unsigned int count = 0;
	Protocol * __unsafe_unretained *sub = protocol_copyProtocolList(proto, &count);
	if (sub) {
		for (unsigned int i = 0; i < count; i++) {
			d = find_proto_method(sub[i], sel, visited);
			if (d.types) {
				free(sub);
				return d;
			}
		}
		free(sub);
	}
	return empty;
}

static NSSet<Class> *build_allowed_ct_classes(void)
{
	static NSSet<Class> *cached;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableSet<Class> *set = [NSMutableSet setWithObjects:
			[NSObject class], [NSArray class], [NSMutableArray class],
			[NSDictionary class], [NSMutableDictionary class],
			[NSSet class], [NSMutableSet class],
			[NSString class], [NSMutableString class],
			[NSNumber class], [NSData class], [NSMutableData class],
			[NSDate class], [NSUUID class], [NSURL class],
			[NSError class], [NSNull class], nil];
		unsigned int count = 0;
		Class *list = objc_copyClassList(&count);
		if (list) {
			Protocol *secProto = objc_getProtocol("NSSecureCoding");
			for (unsigned int i = 0; i < count; i++) {
				const char *nm = class_getName(list[i]);
				if (nm && nm[0] == 'C' && (nm[1] == 'T' || nm[1] == 'N')) {
					if (!secProto || class_conformsToProtocol(list[i], secProto))
						[set addObject:list[i]];
				}
			}
			free(list);
		}
		cached = [set copy];
	});
	return cached;
}

/* ---- CoreTelephony XPC Exported Object & Listener ---- */

static void save_settings(void);
static void follow_switches(void);
static bool modem_settled(void);
static void broadcast_data_settings(bool roaming_changed);

@interface HotCellularXPCService : NSObject
@property (nonatomic, weak) HotXPCConnectionSPI *connection;
@property (nonatomic, assign) BOOL registeredNotifications;
@end

/* (sweetcelld) the CTDataSettings object CoreTelephony clients get and are pushed (dataSettingsChanged:) */
static id build_data_settings(void)
{
	Class cls = NSClassFromString(@"CTDataSettings");
	id ds = cls ? [[cls alloc] init] : nil;
	ct_set(ds, @"cellularDataEnabled", @(g_cellular_data_enabled));
	ct_set(ds, @"airplaneModeEnabled", @(g_airplane_mode));
	ct_set(ds, @"cellularDataCapable", @(YES));
	return ds;
}

static os_unfair_lock g_clients_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<HotCellularXPCService *> *g_xpc_clients;
static NSMutableSet<NSString *> *g_logged_unhandled;
static void trigger_qmi_radio_power(bool online);

@implementation HotCellularXPCService

/* -- Base Interface -- */

- (void)ping:(void (^)(NSError *))completion
{
	if (completion)
		completion(nil);
}

- (void)registerForNotifications:(NSArray *)notifications completion:(void (^)(NSError *))completion
{
	(void)notifications;
	self.registeredNotifications = YES;
	if (completion)
		completion(nil);
}

- (void)getSubscriptionInfo:(void (^)(id, NSError *))completion
{
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(build_subscription_info(&st), nil);
}

- (void)getActiveContexts:(void (^)(id, NSError *))completion
{
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(build_active_contexts(&st), nil);
}

- (void)getDescriptorsForDomain:(NSInteger)domain completion:(void (^)(id, NSError *))completion
{
	(void)domain;
	Class ccls = NSClassFromString(@"CTServiceDescriptorContainer");
	id d = build_slot1_descriptor();
	id cont = ccls ? [(HotCTServiceDescriptorContainer *)[ccls alloc]
			  initWithDescriptors:(d ? @[d] : @[])] : nil;
	if (completion)
		completion(cont, nil);
}

- (void)getDualSimCapability:(void (^)(NSInteger, NSError *))completion
{
	if (completion)
		completion(1, nil); /* Single active SIM */
}

- (void)getEvolvedSubscriptionLabelID:(id)ctx withCallback:(void (^)(NSString *, NSError *))cb
{
	(void)ctx;
	if (cb)
		cb(@SLOT1_UUID_STR, nil);
}

/* -- Subscriber / SIM Interface -- */

- (void)getSIMStatus:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(sim_status_string(&st), nil);
}

- (void)getSIMTrayStatus:(void (^)(NSString *, NSError *))completion
{
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(st.sim_present ? @"kCTSIMSupportSIMTrayInsertedWithSIM"
					  : @"kCTSIMSupportSIMTrayInsertedNoSIM", nil);
}

- (void)getShortLabels:(id)ctx completion:(void (^)(NSDictionary *, NSError *))completion
{
	(void)ctx;
	if (completion)
		completion(@{ @SLOT1_UUID_STR: @"P" }, nil);
}

- (void)isSimLocked:(id)ctx completion:(void (^)(BOOL, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	BOOL locked = (!strcmp(st.sim_state, "pin_locked") || !strcmp(st.sim_state, "puk_locked"));
	if (completion)
		completion(locked, nil);
}

- (void)simHardwareInfo:(id)ctx completion:(void (^)(id, NSError *))completion
{
	(void)ctx;
	Class cls = NSClassFromString(@"CTSimHardwareInfo");
	id hw = cls ? [(HotCTSimHardwareInfo *)[cls alloc] initWithHardwareInfo:1 simLocation:1] : nil;
	if (completion)
		completion(hw, nil);
}

/* -- Registration & Signal Interface -- */

- (void)copyOperatorName:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	NSString *op = st.operator_name[0] ? [NSString stringWithUTF8String:st.operator_name] : @"";
	if (completion)
		completion(op, nil);
}

- (void)copyRegistrationStatus:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(reg_status_string(&st), nil);
}

- (void)copyRegistrationDisplayStatus:(id)ctx completion:(void (^)(id, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(build_display_status(&st), nil);
}

- (void)getSignalStrengthInfo:(id)ctx completion:(void (^)(id, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(build_signal_info(&st), nil);
}

- (void)getPublicSignalStrength:(id)desc completion:(void (^)(id, NSError *))completion
{
	(void)desc;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(build_signal_info(&st), nil);
}

- (void)getSignalStrengthMeasurements:(id)desc completion:(void (^)(id, NSError *))completion
{
	(void)desc;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(build_signal_measurements(&st), nil);
}

- (void)copyMobileCountryCode:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	NSString *mcc = st.mcc[0] ? [NSString stringWithUTF8String:st.mcc] : @"";
	if (completion)
		completion(mcc, nil);
}

- (void)copyLastKnownMobileCountryCode:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	[self copyMobileCountryCode:ctx completion:completion];
}

- (void)copyMobileNetworkCode:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	NSString *mnc = st.mnc[0] ? [NSString stringWithUTF8String:st.mnc] : @"";
	if (completion)
		completion(mnc, nil);
}

- (void)copyServingPlmn:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	NSString *plmn = (st.mcc[0] && st.mnc[0])
			 ? [NSString stringWithFormat:@"%s%s", st.mcc, st.mnc] : @"";
	if (completion)
		completion(plmn, nil);
}

- (void)copyRadioAccessTechnology:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(reg_rat_string(&st), nil);
}

- (void)copyIsDataAttached:(id)ctx completion:(void (^)(BOOL, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(st.sim_present && st.reg_state_raw == 1 && st.ps_attached, nil);
}

- (void)copyIsInHomeCountry:(id)ctx completion:(void (^)(BOOL, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(!st.roaming, nil);
}

- (void)isNetworkSelectionMenuAvailable:(id)ctx completion:(void (^)(BOOL, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(st.sim_present, nil);
}

- (void)copyNetworkSelectionMode:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	(void)ctx;
	if (completion)
		completion(@"kCTRegistrationNetworkSelectionModeAutomatic", nil);
}

- (void)copyNetworkSelectionState:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	(void)ctx;
	if (completion)
		completion(@"kCTRegistrationNetworkSelectionStateIdle", nil);
}

- (void)copyNetworkSelectionInfo:(id)ctx completion:(void (^)(id, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	Class cls = NSClassFromString(@"CTNetworkSelectionInfo");
	id info = cls ? [[cls alloc] init] : nil;
	ct_set(info, @"selectionState", @(1));
	ct_set(info, @"selectionMode", @(0)); /* Automatic */
	Class ncls = NSClassFromString(@"CTNetwork");
	if (ncls && st.operator_name[0]) {
		id net = [[ncls alloc] init];
		ct_set(net, @"name", [NSString stringWithUTF8String:st.operator_name]);
		ct_set(net, @"plmn", [NSString stringWithFormat:@"%s%s", st.mcc, st.mnc]);
		ct_set(net, @"rat", @"LTE");
		ct_set(info, @"selection", net);
	}
	if (completion)
		completion(info, nil);
}

- (void)copyRatSelection:(id)ctx completion:(void (^)(id, NSError *))completion
{
	(void)ctx;
	Class cls = NSClassFromString(@"CTRatSelection");
	id rs = cls ? [[cls alloc] init] : nil;
	ct_set(rs, @"mask", @(7)); /* GSM | UMTS | LTE */
	ct_set(rs, @"selection", @"kCTRegistrationRATSelectionLTE");
	ct_set(rs, @"preferred", @"kCTRegistrationRATSelectionLTE");
	if (completion)
		completion(rs, nil);
}

/* -- Data & Carrier Bundle Interface -- */

- (void)getDataStatus:(id)ctx completion:(void (^)(id, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(build_data_status(&st), nil);
}

- (void)getDataStatusBasic:(id)ctx completion:(void (^)(id, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(build_data_status_basic(&st), nil);
}

- (void)getCurrentDataSubscriptionContext:(void (^)(id, NSError *))completion
{
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(st.sim_present ? build_slot1_context(&st) : nil, nil);
}

- (void)getPreferredDataSubscriptionContext:(void (^)(id, NSError *))completion
{
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(st.sim_present ? build_slot1_context(&st) : nil, nil);
}

- (void)getCurrentDataServiceDescriptor:(void (^)(id, NSError *))completion
{
	if (completion)
		completion(build_slot1_descriptor(), nil);
}

- (void)getPreferredDataServiceDescriptor:(void (^)(id, NSError *))completion
{
	if (completion)
		completion(build_slot1_descriptor(), nil);
}

- (void)getCellularDataIsEnabled:(void (^)(BOOL, NSError *))completion
{
	if (completion)
		completion(g_cellular_data_enabled, nil);
}

- (void)setCellularDataIsEnabled:(BOOL)enabled completion:(void (^)(NSError *))completion
{
	g_cellular_data_enabled = enabled;
	clog("Settings toggled Cellular Data -> %d", enabled ? 1 : 0);
	save_settings();
	broadcast_data_settings(false);
	follow_switches();
	if (completion)
		completion(nil);
}

/* iOS 26's names (CTXPCServiceDataInterface): the Data Roaming switch */
- (void)getInternationalDataAccess:(id)ctx completion:(void (^)(BOOL, NSError *))completion
{
	(void)ctx;
	if (completion)
		completion(g_data_roaming, nil);
}

- (void)setInternationalDataAccess:(id)ctx status:(BOOL)roam completion:(void (^)(NSError *))completion
{
	[self setInternationalDataAccessStatus:ctx status:roam completion:completion];
}

- (void)getDataSettings:(void (^)(id, NSError *))completion
{
	if (completion)
		completion(build_data_settings(), nil);
}

- (void)getSupports5G:(void (^)(BOOL, NSError *))completion
{
	if (completion)
		completion(NO, nil); /* SM8150 / SDX24/internal LTE modem */
}

- (void)getNREnabled:(id)ctx completion:(void (^)(BOOL, NSError *))completion
{
	(void)ctx;
	if (completion)
		completion(NO, nil);
}

- (void)getInternationalDataAccessStatus:(id)ctx completion:(void (^)(BOOL, NSError *))completion
{
	(void)ctx;
	if (completion)
		completion(g_data_roaming, nil);
}

- (void)setInternationalDataAccessStatus:(id)ctx status:(BOOL)roam completion:(void (^)(NSError *))completion
{
	(void)ctx;
	g_data_roaming = roam;
	clog("Settings toggled Data Roaming -> %d", roam ? 1 : 0);
	save_settings();
	broadcast_data_settings(true);
	follow_switches();
	if (completion)
		completion(nil);
}

- (void)getConfiguredApns:(id)ctx completion:(void (^)(NSArray *, NSError *))completion
{
	(void)ctx;
	struct cellular_state st = snapshot_state();
	const char *fb = qmi_resolve_fallback_apn(&st);
	NSString *apn = st.data_apn[0] ? [NSString stringWithUTF8String:st.data_apn]
			: (g_configured_apn[0] ? [NSString stringWithUTF8String:g_configured_apn]
			   : (fb ? [NSString stringWithUTF8String:fb] : @"internet"));
	if (completion)
		completion(@[ @{ @"apn": apn } ], nil);
}

/* -- Stewie, Capabilities, PNR, Private Network & Voicemail Interfaces -- */

- (void)getStewieSupport:(void (^)(id, NSError *))completion
{
	Class cls = NSClassFromString(@"CTStewieSupport");
	id obj = cls ? [[cls alloc] init] : nil;
	ct_set(obj, @"status", @(NO));
	ct_set(obj, @"hwSupport", @(NO));
	if (completion)
		completion(obj, nil);
}

- (void)getPhoneServicesDeviceInfo:(void (^)(NSDictionary *, NSError *))completion
{
	if (completion)
		completion(@{}, nil);
}

- (void)getPNRSupportStatus:(id)ctx completion:(void (^)(id, NSError *))completion
{
	(void)ctx;
	Class cls = NSClassFromString(@"CTPNRSupportStatus");
	id obj = cls ? [[cls alloc] init] : nil;
	ct_set(obj, @"supportType", @(0));
	if (completion)
		completion(obj, nil);
}

- (void)getPrivateNetworkCapabilitiesForContext:(id)ctx completion:(void (^)(id, NSError *))completion
{
	(void)ctx;
	Class cls = NSClassFromString(@"CTPrivateNetworkCapabilities");
	id obj = cls ? [[cls alloc] init] : nil;
	ct_set(obj, @"isPrivateNetworkSIM", @(NO));
	ct_set(obj, @"isPrivateNetworkPreferredOverWifi", @(NO));
	ct_set(obj, @"isPrivateNetworkModeEnabled", @(NO));
	ct_set(obj, @"hideDataRoaming", @(NO));
	if (completion)
		completion(obj, nil);
}

- (void)getVoicemailCallInDetails:(id)ctx completion:(void (^)(NSDictionary *, NSError *))completion
{
	(void)ctx;
	if (completion)
		completion(@{}, nil);
}

- (void)context:(id)ctx getCapability:(NSString *)cap completion:(void (^)(BOOL, NSDictionary *, NSError *))completion
{
	(void)ctx;
	BOOL enabled = ([cap isEqualToString:@"kCTCapabilityPhoneServices"] ||
			[cap isEqualToString:@"kCTCapabilityVoLTE"]);
	NSDictionary *info = [cap isEqualToString:@"kCTCapabilityPhoneServices"] ? @{
		@"kCTCapabilityAgent": @YES,
		@"kCTCapabilityAgent2": @YES,
		@"kCTCallManagementIsPhoneServicesActive": @YES,
		@"kCTCallManagementPhoneServicesCSCallingAvailable": @YES,
		@"kCTCallManagementPhoneServicesVoLTECallingAvailable": @YES,
		@"kCTCallManagementEmergencyWifiAllowed": @NO,
		@"kCTCallManagementEmergencyWifiCallCapable": @NO,
	} : @{};
	if (completion)
		completion(enabled, info, nil);
}

- (void)getVoicemailInfo:(id)ctx completion:(void (^)(BOOL, NSNumber *, NSString *, NSError *))completion
{
	(void)ctx;
	if (completion)
		completion(NO, @(0), @"", nil);
}

- (void)copyCarrierBundleVersion:(id)ctx completion:(void (^)(NSString *, NSError *))completion
{
	(void)ctx;
	if (completion)
		completion(@"64.0", nil);
}

static id build_call_capabilities_obj(void)
{
	Class cls = NSClassFromString(@"CTCallCapabilities");
	id caps = cls ? [[cls alloc] init] : nil;
	ct_set(caps, @"isCSCallingAvailable", @NO);
	ct_set(caps, @"isVoLTECallingAvailable", @NO);
	ct_set(caps, @"isWiFiCallingAvailable", @NO);
	ct_set(caps, @"isEmergencyCallingOnWifiAllowed", @NO);
	ct_set(caps, @"isEmergencyCallingOnWifiAvailable", @NO);
	ct_set(caps, @"isCarrierSupportsWiFiCallingOnOtherDevices", @NO);
	return caps;
}

static NSDictionary *build_system_capabilities_dict(void)
{
	return @{
		@"kCTCapabilityPhoneServices": @{
			@"kCTCapabilityAgent": @YES,
			@"kCTCapabilityAgent2": @YES,
			@"kCTCallManagementIsPhoneServicesActive": @NO,
			@"kCTCallManagementPhoneServicesCSCallingAvailable": @NO,
			@"kCTCallManagementPhoneServicesVoLTECallingAvailable": @NO,
			@"kCTCallManagementEmergencyWifiAllowed": @NO,
			@"kCTCallManagementEmergencyWifiCallCapable": @NO,
		},
	};
}

static id resolve_carrier_bundle_val(const struct cellular_state *st, id keyHierarchy, id defaultVal)
{
	NSString *k = @"";
	if ([keyHierarchy isKindOfClass:[NSArray class]] && [(NSArray *)keyHierarchy count] > 0)
		k = [[(NSArray *)keyHierarchy lastObject] description];
	else if ([keyHierarchy isKindOfClass:[NSString class]])
		k = (NSString *)keyHierarchy;

	id val = nil;
	if ([k isEqualToString:@"CarrierName"] || [k isEqualToString:@"MVNOCarrierName"]) {
		val = st->operator_name[0] ? [NSString stringWithUTF8String:st->operator_name] : @"Carrier";
	} else if ([k isEqualToString:@"StatusBarImages"]) {
		NSString *nm = st->operator_name[0] ? [NSString stringWithUTF8String:st->operator_name] : @"";
		val = @[ @{ @"StatusBarCarrierName": nm, @"AllowPrefixMatching": @YES } ];
	} else if ([k isEqualToString:@"Show3GSwitch"] || [k isEqualToString:@"LTEConnectionShows4G"]) {
		val = @NO;
	} else if ([k isEqualToString:@"Show4GSwitch"] || [k isEqualToString:@"AllowEDGEEditing"] ||
		   [k isEqualToString:@"VoLTEEnabled"] || [k isEqualToString:@"SupportsCallsOverIMS"] ||
		   [k isEqualToString:@"ShowCallForwarding"] || [k isEqualToString:@"ShowCallWaiting"]) {
		val = [k isEqualToString:@"Show4GSwitch"] || [k isEqualToString:@"AllowEDGEEditing"] ? @YES : @NO;
	}
	return val ? val : defaultVal;
}

- (void)copyCarrierBundleValue:(id)ctx key:(NSArray *)keyHierarchy
		    bundleType:(id)btype completion:(void (^)(id, NSError *))completion
{
	[self copyCarrierBundleValueWithDefault:ctx key:keyHierarchy bundleType:btype completion:completion];
}

- (void)copyCarrierBundleValueWithDefault:(id)ctx key:(NSArray *)keyHierarchy
			       bundleType:(id)btype completion:(void (^)(id, NSError *))completion
{
	(void)ctx; (void)btype;
	struct cellular_state st = snapshot_state();
	if (completion)
		completion(resolve_carrier_bundle_val(&st, keyHierarchy, nil), nil);
}

/* -- Unified CTXPCRequestMessage Dispatcher (sendRequest:completionHandler:) -- */

- (void)sendRequest:(id)request completionHandler:(void (^)(id response, NSError *error))completionHandler
{
	if (!completionHandler)
		return;
	if (!request) {
		completionHandler(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]);
		return;
	}

	@try {
		NSString *cname = NSStringFromClass([request class]);
		struct cellular_state st = snapshot_state();
		id resp = nil;

		if ([cname isEqualToString:@"CTXPCGetSignalStrengthInfoRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetSignalStrengthInfoResponse");
			resp = rcls ? [(HotCTSigInfoResp *)[rcls alloc]
				       initWithSignalStrengthInfo:build_signal_info(&st)] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetSignalStrengthMeasurementsRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetSignalStrengthMeasurementsResponse");
			resp = rcls ? [(HotCTSigMeasResp *)[rcls alloc]
				       initWithSignalStrengthMeasurements:build_signal_measurements(&st)] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetOperatorNameRequest"] ||
			   [cname isEqualToString:@"CTXPCSubscriptionNameRequest"]) {
			NSString *op = st.operator_name[0] ? [NSString stringWithUTF8String:st.operator_name] : @"";
			if ([cname isEqualToString:@"CTXPCGetOperatorNameRequest"]) {
				Class rcls = NSClassFromString(@"CTXPCGetOperatorNameResponse");
				resp = rcls ? [(HotCTOpNameResp *)[rcls alloc] initWithOperatorName:op] : nil;
			} else {
				Class rcls = NSClassFromString(@"CTXPCSimCommonResultResponse");
				resp = rcls ? [(HotCTObjResp *)[rcls alloc] initWithResult:(op.length ? op : @"Primary")] : nil;
			}
		} else if ([cname isEqualToString:@"CTXPCGetRegistrationStatusRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetRegistrationStatusResponse");
			resp = rcls ? [(HotCTStatusResp *)[rcls alloc] initWithStatus:reg_status_string(&st)] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetRegistrationDisplayStatusRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetRegistrationDisplayStatusResponse");
			resp = rcls ? [(HotCTStatusResp *)[rcls alloc] initWithStatus:build_display_status(&st)] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetRoamingStatusRequest"]) {
			Class mcls = NSClassFromString(@"CTRoamingStatus");
			id rm = mcls ? [[mcls alloc] init] : nil;
			ct_set(rm, @"isVoiceRoaming", @(st.roaming));
			ct_set(rm, @"isDataRoaming", @(st.roaming));
			Class rcls = NSClassFromString(@"CTXPCGetRoamingStatusResponse");
			resp = rcls ? [(HotCTRoamingResp *)[rcls alloc] initWithRoamingStatus:rm] : nil;
		} else if ([cname isEqualToString:@"CTXPCSimStatusRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCSimCommonResultResponse");
			resp = rcls ? [(HotCTObjResp *)[rcls alloc] initWithResult:sim_status_string(&st)] : nil;
		} else if ([cname isEqualToString:@"CTXPCSimTrayStatusRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCSimCommonResultResponse");
			NSString *tray = st.sim_present ? @"kCTSIMSupportSIMTrayInsertedWithSIM"
							: @"kCTSIMSupportSIMTrayInsertedNoSIM";
			resp = rcls ? [(HotCTObjResp *)[rcls alloc] initWithResult:tray] : nil;
		} else if ([cname isEqualToString:@"CTXPCSimHardwareInfoRequest"]) {
			Class hcls = NSClassFromString(@"CTSimHardwareInfo");
			id hw = hcls ? [(HotCTSimHardwareInfo *)[hcls alloc] initWithHardwareInfo:1 simLocation:1] : nil;
			Class rcls = NSClassFromString(@"CTXPCSimHardwareInfoResponse");
			resp = rcls ? [(HotCTHwResp *)[rcls alloc] initWithHardwareInfo:hw] : nil;
		} else if ([cname isEqualToString:@"CTXPCSimLockStateRequest"]) {
			/* 0 = unlocked, 1 = PIN locked, 2 = PUK locked */
			int lstate = 0;
			if (!strcmp(st.sim_state, "pin_locked")) lstate = 1;
			else if (!strcmp(st.sim_state, "puk_locked")) lstate = 2;
			Class rcls = NSClassFromString(@"CTXPCSimCommonNumberResultResponse");
			resp = rcls ? [(HotCTObjResp *)[rcls alloc] initWithResult:@(lstate)] : nil;
		} else if ([cname isEqualToString:@"CTXPCRemainingPINRetriesRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCSimCommonNumberResultResponse");
			resp = rcls ? [(HotCTObjResp *)[rcls alloc] initWithResult:@(st.pin1_retries)] : nil;
		} else if ([cname isEqualToString:@"CTXPCRemainingPUKRetriesRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCSimCommonNumberResultResponse");
			resp = rcls ? [(HotCTObjResp *)[rcls alloc] initWithResult:@(st.puk1_retries)] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetSimLabelRequest"]) {
			Class lcls = NSClassFromString(@"CTSimLabel");
			id lbl = lcls ? [(HotCTSimLabel *)[lcls alloc]
					 initWithId:@SLOT1_UUID_STR andText:@"Primary" andDidSetup:YES] : nil;
			Class rcls = NSClassFromString(@"CTXPCGetSimLabelResponse");
			resp = rcls ? [(HotCTLabelResp *)[rcls alloc] initWithLabel:lbl] : nil;
		} else if ([cname isEqualToString:@"CTXPCShortLabelRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCSimCommonResultResponse");
			resp = rcls ? [(HotCTObjResp *)[rcls alloc] initWithResult:@"P"] : nil;
		} else if ([cname isEqualToString:@"CTXPCIsAnySimReadyRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCBooleanResponseMessage");
			BOOL rdy = st.sim_present &&
				   (!strcmp(st.app_state, "ready") || !strcmp(st.app_state, "subscription_ready"));
			resp = rcls ? [(HotCTBoolResp *)[rcls alloc] initWithResult:rdy] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetIsDataAttachedRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetIsDataAttachedResponse");
			BOOL att = st.sim_present && st.reg_state_raw == 1 && st.ps_attached;
			resp = rcls ? [(HotCTDataAttResp *)[rcls alloc] initWithIsDataAttached:att] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetIsInHomeCountryRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetIsInHomeCountryResponse");
			resp = rcls ? [(HotCTHomeResp *)[rcls alloc] initWithIsHome:!st.roaming] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetMobileCountryCodeRequest"] ||
			   [cname isEqualToString:@"CTXPCMobileSubscriberCountryCodeRequest"] ||
			   [cname isEqualToString:@"CTXPCLastKnownMobileSubscriberCountryCodeRequest"]) {
			NSString *mcc = st.mcc[0] ? [NSString stringWithUTF8String:st.mcc] : @"";
			if ([cname isEqualToString:@"CTXPCGetMobileCountryCodeRequest"]) {
				Class rcls = NSClassFromString(@"CTXPCGetMobileCountryCodeResponse");
				resp = rcls ? [(HotCTMccResp *)[rcls alloc] initWithMcc:mcc] : nil;
			} else {
				Class rcls = NSClassFromString(@"CTXPCSimCommonResultResponse");
				resp = rcls ? [(HotCTObjResp *)[rcls alloc] initWithResult:mcc] : nil;
			}
		} else if ([cname isEqualToString:@"CTXPCGetLastKnownMobileCountryCodeRequest"]) {
			NSString *mcc = st.mcc[0] ? [NSString stringWithUTF8String:st.mcc] : @"";
			Class rcls = NSClassFromString(@"CTXPCGetLastKnownMobileCountryCodeResponse");
			resp = rcls ? [(HotCTLastMccResp *)[rcls alloc] initWithLastMcc:mcc] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetMobileNetworkCodeRequest"] ||
			   [cname isEqualToString:@"CTXPCMobileSubscriberNetworkCodeRequest"]) {
			NSString *mnc = st.mnc[0] ? [NSString stringWithUTF8String:st.mnc] : @"";
			if ([cname isEqualToString:@"CTXPCGetMobileNetworkCodeRequest"]) {
				Class rcls = NSClassFromString(@"CTXPCGetMobileNetworkCodeResponse");
				resp = rcls ? [(HotCTMncResp *)[rcls alloc] initWithMnc:mnc] : nil;
			} else {
				Class rcls = NSClassFromString(@"CTXPCSimCommonResultResponse");
				resp = rcls ? [(HotCTObjResp *)[rcls alloc] initWithResult:mnc] : nil;
			}
		} else if ([cname isEqualToString:@"CTXPCGetServingPlmnRequest"]) {
			NSString *plmn = (st.mcc[0] && st.mnc[0])
					 ? [NSString stringWithFormat:@"%s%s", st.mcc, st.mnc] : @"";
			Class rcls = NSClassFromString(@"CTXPCGetServingPlmnResponse");
			resp = rcls ? [(HotCTPlmnResp *)[rcls alloc] initWithPlmn:plmn] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetCurrentRatRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetCurrentRatResponse");
			resp = rcls ? [(HotCTCurRatResp *)[rcls alloc] initWithRat:public_rat_string(&st)] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetRadioAccessTechnologyRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetRadioAccessTechnologyResponse");
			resp = rcls ? [(HotCTRegRatResp *)[rcls alloc] initWithRAT:reg_rat_string(&st)] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetWirelessTechnologyRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetWirelessTechnologyResponse");
			resp = rcls ? [(HotCTTechResp *)[rcls alloc] initWithTechnology:@"UMTS"] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetRatSelectionRequest"]) {
			Class scls = NSClassFromString(@"CTRatSelection");
			id rs = scls ? [[scls alloc] init] : nil;
			ct_set(rs, @"mask", @(7));
			ct_set(rs, @"selection", @"kCTRegistrationRATSelectionLTE");
			ct_set(rs, @"preferred", @"kCTRegistrationRATSelectionLTE");
			Class rcls = NSClassFromString(@"CTXPCGetRatSelectionResponse");
			resp = rcls ? [(HotCTRatSelResp *)[rcls alloc] initWithRATSelection:rs] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetMaxDataRateRequest"]) {
			/* 3 = kCTRegistrationDataRate4G / LTE */
			Class rcls = NSClassFromString(@"CTXPCGetMaxDataRateResponse");
			resp = rcls ? [(HotCTDataRateResp *)[rcls alloc] initWithDataRate:3] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetSupportedDataRatesRequest"]) {
			Class scls = NSClassFromString(@"CTSupportedMaxDataRates");
			id sr = scls ? [(HotCTSupportedMaxDataRates *)[scls alloc] initWithRates:@[@2, @3]] : nil;
			Class rcls = NSClassFromString(@"CTXPCGetSupportedDataRatesResponse");
			resp = rcls ? [(HotCTSupRatesResp *)[rcls alloc] initWithSupportedRates:sr] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetNRStatusRequest"]) {
			Class ncls = NSClassFromString(@"CTNRStatus");
			id nr = ncls ? [[ncls alloc] init] : nil;
			ct_set(nr, @"saSwitchVisible", @(NO));
			ct_set(nr, @"saSwitchConfigurable", @(NO));
			ct_set(nr, @"saDisabled", @(YES));
			ct_set(nr, @"nsaDisabled", @(YES));
			Class rcls = NSClassFromString(@"CTXPCGetNRStatusResponse");
			resp = rcls ? [(HotCTNRResp *)[rcls alloc] initWithNRStatus:nr] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetSupports5GStandaloneRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetSupports5GStandaloneResponse");
			resp = rcls ? [(HotCTSupportResp *)[rcls alloc] initWithSupport:NO] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetBandInfoRequest"]) {
			Class bcls = NSClassFromString(@"CTBandInfo");
			id bi = bcls ? [[bcls alloc] init] : nil;
			Class rcls = NSClassFromString(@"CTXPCGetBandInfoResponse");
			resp = rcls ? [(HotCTBandResp *)[rcls alloc] initWithBandInfo:bi] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetDefaultVoiceRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetDefaultVoiceResponse");
			resp = rcls ? [(HotCTCtxResp *)[rcls alloc]
				       initWithContext:(st.sim_present ? build_slot1_context(&st) : nil)] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetIsNetworkSelectionMenuAvailableRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetIsNetworkSelectionMenuAvailableResponse");
			resp = rcls ? [(HotCTAvailResp *)[rcls alloc] initWithIsAvailable:st.sim_present] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetIsNetworkReselectionNeededRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetIsNetworkReselectionNeededResponse");
			resp = rcls ? [(HotCTReselResp *)[rcls alloc] initWithNeedsReselection:NO] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetNetworkSelectionInfoRequest"]) {
			Class icls = NSClassFromString(@"CTNetworkSelectionInfo");
			id info = icls ? [[icls alloc] init] : nil;
			ct_set(info, @"selectionState", @(1));
			ct_set(info, @"selectionMode", @(0));
			Class rcls = NSClassFromString(@"CTXPCGetNetworkSelectionInfoResponse");
			resp = rcls ? [(HotCTNetSelInfoResp *)[rcls alloc] initWithNetworkSelectionInfo:info] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetNetworkSelectionRequest"]) {
			Class ncls = NSClassFromString(@"CTNetwork");
			id net = ncls ? [[ncls alloc] init] : nil;
			if (st.operator_name[0])
				ct_set(net, @"name", [NSString stringWithUTF8String:st.operator_name]);
			Class rcls = NSClassFromString(@"CTXPCGetNetworkSelectionResponse");
			resp = rcls ? [(HotCTNetResp *)[rcls alloc] initWithNetwork:net] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetNetworkListRequest"] ||
			   [cname isEqualToString:@"CTXPCFetchNetworkListRequest"]) {
			Class lcls = NSClassFromString(@"CTNetworkList");
			id nl = lcls ? [[lcls alloc] init] : nil;
			ct_set(nl, @"networks", [NSMutableArray array]);
			ct_set(nl, @"moreComing", @(NO));
			Class rcls = NSClassFromString(@"CTXPCGetNetworkListResponse");
			resp = rcls ? [(HotCTNetListResp *)[rcls alloc] initWithNetworkList:nl] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetIMSRegistrationStatusRequest"]) {
			Class icls = NSClassFromString(@"CTIMSRegistrationStatus");
			id ims = icls ? [[icls alloc] init] : nil;
			Class rcls = NSClassFromString(@"CTXPCGetIMSRegistrationStatusResponse");
			resp = rcls ? [(HotCTIMSResp *)[rcls alloc] initWithIMSRegistrationStatus:ims] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetRegistrationIMSTransportInfoRequest"]) {
			Class icls = NSClassFromString(@"CTIMSRegistrationTransportInfo");
			id ims = icls ? [[icls alloc] init] : nil;
			Class rcls = NSClassFromString(@"CTXPCGetRegistrationIMSTransportInfoResponse");
			resp = rcls ? [(HotCTIMSTransResp *)[rcls alloc] initWithIMSRegistrationInfo:ims] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetEncryptionStatusRequest"]) {
			Class ecls = NSClassFromString(@"CTEncryptionStatusInfo");
			id enc = ecls ? [(HotCTEncryptionStatusInfo *)[ecls alloc] initWithStatus:0] : nil;
			Class rcls = NSClassFromString(@"CTXPCGetEncryptionStatusResponse");
			resp = rcls ? [(HotCTEncResp *)[rcls alloc] initWithEncryptionStatusInfo:enc] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetRejectCauseCodeRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCGetRejectCauseCodeResponse");
			resp = rcls ? [(HotCTCauseResp *)[rcls alloc] initWithCauseCode:@(st.last_reject_cause)] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetCallCapabilitiesRequest"]) {
			id caps = build_call_capabilities_obj();
			Class rcls = NSClassFromString(@"CTXPCGetCallCapabilitiesResponse");
			if (rcls) {
				if ([rcls instancesRespondToSelector:@selector(initWithCapabilities:)])
					resp = [(HotCTCallCapResp *)[rcls alloc] initWithCapabilities:caps];
				else {
					resp = [[rcls alloc] init];
					ct_set(resp, @"capabilities", caps);
				}
			}
		} else if ([cname isEqualToString:@"CTXPCSupportEmbeddedSimRequest"] ||
			   [cname isEqualToString:@"CTXPCEmbeddedSIMOnlyConfigRequest"] ||
			   [cname isEqualToString:@"CTXPCNeedToLaunchSetUpeSIMRequest"] ||
			   [cname isEqualToString:@"CTXPCUsingBootstrapDataServiceRequest"] ||
			   [cname isEqualToString:@"CTXPCSupportsHydraRequest"] ||
			   [cname isEqualToString:@"CTXPCSupportsLimitedUseSIMsRequest"] ||
			   [cname isEqualToString:@"CTXPCShouldShoweSIMTravelTipRequest"] ||
			   [cname isEqualToString:@"CTXPCIsMemoryConstrainedRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCBooleanResponseMessage");
			resp = rcls ? [(HotCTBoolResp *)[rcls alloc] initWithResult:NO] : nil;
		} else if ([cname isEqualToString:@"CTXPCEmbeddedSIMHealthRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCBooleanResponseMessage");
			resp = rcls ? [(HotCTBoolResp *)[rcls alloc] initWithResult:YES] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetPendingInstallPlansRequest"]) {
			Class dcls = NSClassFromString(@"CTDisplayPlanList");
			id empty = dcls ? [(HotCTDisplayPlanList *)[dcls alloc] initWithDisplayPlans:@[]] : nil;
			Class rcls = NSClassFromString(@"CTXPCGetPendingInstallPlansResponse");
			resp = rcls ? [(HotCTPlanListResp *)[rcls alloc] initWithPlanList:empty] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetCarrierSetupItemsRequest"] ||
			   [cname isEqualToString:@"CTXPCGetHiddenTransferPlansRequest"] ||
			   [cname isEqualToString:@"CTXPCGetPlansPendingCrossPlatformTransferRequest"]) {
			Class dcls = NSClassFromString(@"CTDisplayPlanList");
			id empty = dcls ? [(HotCTDisplayPlanList *)[dcls alloc] initWithDisplayPlans:@[]] : nil;
			Class rcls = NSClassFromString([cname stringByReplacingOccurrencesOfString:@"Request"
											withString:@"Response"]);
			resp = rcls ? [(HotCTListResp *)[rcls alloc] initWithList:empty] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetRemoteDevicesRequest"]) {
			Class lcls = NSClassFromString(@"CTRemoteDeviceList");
			id empty = lcls ? [[lcls alloc] init] : nil;
			ct_set(empty, @"devices", [NSMutableArray array]);
			Class rcls = NSClassFromString(@"CTXPCGetRemoteDevicesResponse");
			resp = rcls ? [(HotCTListResp *)[rcls alloc] initWithList:empty] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetRemoteDevicesForTransferRequest"]) {
			Class lcls = NSClassFromString(@"CTRemoteDeviceList");
			id empty = lcls ? [[lcls alloc] init] : nil;
			ct_set(empty, @"devices", [NSMutableArray array]);
			Class rcls = NSClassFromString(@"CTXPCGetRemoteDevicesForTransferResponse");
			resp = rcls ? [(HotCTDevsResp *)[rcls alloc] initWithDevices:empty] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetTransferPlansRequest"]) {
			Class lcls = NSClassFromString(@"CTRemoteDeviceList");
			id empty = lcls ? [[lcls alloc] init] : nil;
			ct_set(empty, @"devices", [NSMutableArray array]);
			Class rcls = NSClassFromString(@"CTXPCGetTransferPlansResponse");
			resp = rcls ? [(HotCTTransferPlansResp *)[rcls alloc]
				       initWithRemtoeDevices:empty isFlexPolicyOn:NO] : nil;
		} else if ([cname isEqualToString:@"CTXPCGet2GSwitchEnabledRequest"] ||
			   [cname isEqualToString:@"CTXPCGet2GUserPreferenceRequest"] ||
			   [cname isEqualToString:@"CTXPCGetRegulatedRATsSwitchEnabledRequest"] ||
			   [cname isEqualToString:@"CTXPCGetRegulatedRATsUserPreferenceRequest"]) {
			Class rcls = NSClassFromString([cname stringByReplacingOccurrencesOfString:@"Request"
											withString:@"Response"]);
			resp = rcls ? [(HotCTEnabledResp *)[rcls alloc] initWithIsEnabled:NO] : nil;
		} else if ([cname isEqualToString:@"CTXPCMobileEquipmentInfoRequest"]) {
			/* Privacy-safe equipment info: firmware baseVersion only, NO IMEI/ICCID/IMSI */
			Class mcls = NSClassFromString(@"CTMobileEquipmentInfo");
			Class lcls = NSClassFromString(@"CTMobileEquipmentInfoList");
			id me = mcls ? [[mcls alloc] init] : nil;
			ct_set(me, @"slotId", @(1));
			if (st.modem_rev[0])
				ct_set(me, @"baseVersion", [NSString stringWithUTF8String:st.modem_rev]);
			id list = lcls ? [[lcls alloc] init] : nil;
			ct_set(list, @"meInfoList", me ? @[me] : @[]);
			Class rcls = NSClassFromString(@"CTXPCMobileEquipmentInfoResponse");
			resp = rcls ? [(HotCTMeInfoResp *)[rcls alloc] initWithEquipmentInfoList:list] : nil;
		} else if ([cname isEqualToString:@"CTXPCGetDeviceInfoRequest"]) {
			NSString *fw = st.modem_rev[0] ? [NSString stringWithUTF8String:st.modem_rev] : @"SM8150-MPSS";
			Class rcls = NSClassFromString(@"CTXPCGetDeviceInfoResponse");
			resp = rcls ? [(HotCTInfoResp *)[rcls alloc] initWithInfo:@{ @"ModemFirmware": fw }] : nil;
		} else if ([cname isEqualToString:@"CTXPCFirmwareUpdateInfoRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCFirmwareUpdateInfoResponse");
			resp = rcls ? [(HotCTFwInfoResp *)[rcls alloc] initWithFimwareUpdateInfo:@{}] : nil;
		} else if ([cname isEqualToString:@"CTXPCSetDefaultDataRequest"] ||
			   [cname isEqualToString:@"CTXPCSetDefaultVoiceRequest"] ||
			   [cname isEqualToString:@"CTXPCSetRatSelectionRequest"] ||
			   [cname isEqualToString:@"CTXPCSetRatSelectionMaskRequest"] ||
			   [cname isEqualToString:@"CTXPCSetMaxDataRateRequest"] ||
			   [cname isEqualToString:@"CTXPCSaveCellularSettingsRequest"]) {
			Class rcls = NSClassFromString(@"CTXPCResponseMessage");
			resp = rcls ? [[rcls alloc] init] : nil;
		}

		if (resp) {
			completionHandler(resp, nil);
			return;
		}

		os_unfair_lock_lock(&g_clients_lock);
		BOOL first = ![g_logged_unhandled containsObject:cname];
		if (first)
			[g_logged_unhandled addObject:cname];
		os_unfair_lock_unlock(&g_clients_lock);
		if (first)
			clog("unhandled CTXPCRequestMessage: %s", [cname UTF8String]);

		completionHandler(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTSUP userInfo:nil]);
	} @catch (id exc) {
		clog("sendRequest exception: %s", [[exc description] UTF8String]);
		completionHandler(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EFAULT userInfo:nil]);
	}
}

/* -- Type-safe fallback for any unimplemented CTXPCServiceInterface selector -- */

- (BOOL)respondsToSelector:(SEL)aSelector
{
	if ([super respondsToSelector:aSelector])
		return YES;
	Protocol *p = objc_getProtocol("CTXPCServiceInterface");
	if (p) {
		struct objc_method_description d = find_proto_method(p, aSelector, [NSMutableSet set]);
		if (d.types != NULL)
			return YES;
	}
	return NO;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
	NSMethodSignature *sig = [super methodSignatureForSelector:aSelector];
	if (sig)
		return sig;
	Protocol *p = objc_getProtocol("CTXPCServiceInterface");
	if (p) {
		struct objc_method_description d = find_proto_method(p, aSelector, [NSMutableSet set]);
		if (d.types)
			return [NSMethodSignature signatureWithObjCTypes:d.types];
	}
	return nil;
}

static void invoke_ct_reply_block(id replyBlock, BOOL setterOnly,
				  id objVal, BOOL boolVal, NSInteger intVal, NSError *errVal)
{
	if (!replyBlock || !fn_Block_signature)
		return;
	const char *bsig = fn_Block_signature((__bridge void *)replyBlock);
	if (!bsig)
		return;
	NSMethodSignature *bms = [NSMethodSignature signatureWithObjCTypes:bsig];
	if (!bms)
		return;
	NSInvocation *binv = [NSInvocation invocationWithMethodSignature:bms];
	[binv setTarget:replyBlock];
	uint8_t zero[64] = { 0 };
	NSUInteger n = bms.numberOfArguments;
	for (NSUInteger k = 1; k < n; k++) {
		const char *pt = [bms getArgumentTypeAtIndex:k];
		if (!pt) {
			[binv setArgument:zero atIndex:(NSInteger)k];
			continue;
		}
		bool isErrSlot = (strstr(pt, "NSError") != NULL) ||
				 (setterOnly && n == 2 && pt[0] == '@') ||
				 (n >= 3 && k == n - 1 && pt[0] == '@');
		if (isErrSlot) {
			__unsafe_unretained NSError *uerr = errVal;
			[binv setArgument:&uerr atIndex:(NSInteger)k];
		} else if (k == 1) {
			if (pt[0] == '@') {
				__unsafe_unretained id uobj = objVal;
				[binv setArgument:&uobj atIndex:(NSInteger)k];
			} else if (pt[0] == 'B') {
				bool bv = boolVal ? true : false;
				[binv setArgument:&bv atIndex:(NSInteger)k];
			} else if (pt[0] == 'c' || pt[0] == 'C') {
				signed char cv = boolVal ? 1 : 0;
				[binv setArgument:&cv atIndex:(NSInteger)k];
			} else if (pt[0] == 'i' || pt[0] == 'I') {
				int iv = (int)intVal;
				[binv setArgument:&iv atIndex:(NSInteger)k];
			} else if (pt[0] == 'q' || pt[0] == 'Q') {
				long long qv = (long long)intVal;
				[binv setArgument:&qv atIndex:(NSInteger)k];
			} else {
				[binv setArgument:zero atIndex:(NSInteger)k];
			}
		} else {
			[binv setArgument:zero atIndex:(NSInteger)k];
		}
	}
	[binv invoke];
}

- (BOOL)handleDynamicCTSelector:(NSString *)sname invocation:(NSInvocation *)inv
{
	NSMethodSignature *sig = inv.methodSignature;
	NSUInteger argc = sig.numberOfArguments;
	__unsafe_unretained id replyBlock = nil;
	if (argc >= 3) {
		const char *lastType = [sig getArgumentTypeAtIndex:argc - 1];
		if (lastType && strncmp(lastType, "@?", 2) == 0)
			[inv getArgument:&replyBlock atIndex:(NSInteger)(argc - 1)];
	}

	struct cellular_state st = snapshot_state();

	if ([sname isEqualToString:@"getCallCapabilities:completion:"] ||
	    [sname isEqualToString:@"getCallCapabilities:"]) {
		invoke_ct_reply_block(replyBlock, NO, build_call_capabilities_obj(), YES, 1, nil);
		return YES;
	}
	if ([sname isEqualToString:@"context:getSystemCapabilities:"] ||
	    [sname isEqualToString:@"context:getSystemCapabilitiesWithCompletion:"] ||
	    [sname isEqualToString:@"getSystemCapabilities:completion:"]) {
		invoke_ct_reply_block(replyBlock, NO, build_system_capabilities_dict(), YES, 1, nil);
		return YES;
	}
	if ([sname isEqualToString:@"copyCellInfo:completion:"]) {
		Class ccls = NSClassFromString(@"CTCellInfo");
		id ci = ccls ? [[ccls alloc] init] : nil;
		invoke_ct_reply_block(replyBlock, NO, ci, NO, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"smartDataMode:completion:"]) {
		invoke_ct_reply_block(replyBlock, NO, @(NO), NO, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"getEnglishCarrierNameFor:completion:"]) {
		NSString *op = st.operator_name[0] ? [NSString stringWithUTF8String:st.operator_name] : @"";
		invoke_ct_reply_block(replyBlock, NO, op, YES, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"copyCarrierBundleValue:keyHierarchy:bundleType:completion:"] ||
	    [sname isEqualToString:@"copyCarrierBundleValueWithDefault:keyHierarchy:bundleType:completion:"]) {
		__unsafe_unretained id keyHier = nil;
		__unsafe_unretained id defVal = nil;
		if (argc > 3 && [sig getArgumentTypeAtIndex:3][0] == '@')
			[inv getArgument:&keyHier atIndex:3];
		if ([sname hasPrefix:@"copyCarrierBundleValueWithDefault:"] &&
		    argc > 2 && [sig getArgumentTypeAtIndex:2][0] == '@') {
			/* Note: arg2 is context on both; default value if present is nil-safe */
			(void)defVal;
		}
		id val = resolve_carrier_bundle_val(&st, keyHier, nil);
		invoke_ct_reply_block(replyBlock, NO, val, val != nil, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"copyCarrierBookmarks:completion:"]) {
		invoke_ct_reply_block(replyBlock, NO, @[], NO, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"getPNRContext:completion:"]) {
		Class pcls = NSClassFromString(@"CTPNRContextInfo");
		id pnr = pcls ? [[pcls alloc] init] : nil;
		ct_set(pnr, @"isReady", @NO);
		NSString *plmn = (st.mcc[0] && st.mnc[0])
				 ? [NSString stringWithFormat:@"%s%s", st.mcc, st.mnc] : @"";
		ct_set(pnr, @"plmn", plmn);
		invoke_ct_reply_block(replyBlock, NO, pnr, NO, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"getSupports5G:completion:"]) {
		invoke_ct_reply_block(replyBlock, NO, @NO, NO, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"getInternationalDataAccess:completion:"] ||
	    [sname isEqualToString:@"getInternationalDataAccessSync:completion:"]) {
		invoke_ct_reply_block(replyBlock, NO, @(g_data_roaming), g_data_roaming, g_data_roaming ? 1 : 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"getConnectionState:connectionType:completion:"]) {
		Class ccls = NSClassFromString(@"CTDataConnectionStatus");
		id cs = ccls ? [[ccls alloc] init] : nil;
		NSInteger stateInt = st.data_connected ? 2 : 0;
		ct_set(cs, @"state", @(stateInt));
		ct_set(cs, @"ipFamily", @(st.wds_ip_family));
		ct_set(cs, @"interfaceName", st.data_connected ? @"rmnet0" : @"");
		ct_set(cs, @"apnName", st.data_apn[0] ? [NSString stringWithUTF8String:st.data_apn] : @"");
		invoke_ct_reply_block(replyBlock, NO, cs, st.data_connected, stateInt, nil);
		return YES;
	}
	if ([sname isEqualToString:@"getTetheringStatus:connectionType:"] ||
	    [sname isEqualToString:@"getTetheringStatus:connectionType:completion:"] ||
	    [sname isEqualToString:@"getTetheringStatus:completion:"]) {
		Class tcls = NSClassFromString(@"CTTetheringStatus");
		id ts = tcls ? [[tcls alloc] init] : nil;
		ct_set(ts, @"carrierEnabled", @NO);
		ct_set(ts, @"userAuthenticated", @NO);
		ct_set(ts, @"misPdpMaxHosts", @0);
		invoke_ct_reply_block(replyBlock, NO, ts, NO, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"refreshCellMonitor:completion:"] ||
	    [sname isEqualToString:@"setPacketContextActiveByServiceType:connectionType:active:completion:"] ||
	    [sname isEqualToString:@"setAssertionForConnectionType:enable:completion:"]) {
		invoke_ct_reply_block(replyBlock, YES, @YES, YES, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"reliableNetworkFallback:completion:"]) {
		Class rcls = NSClassFromString(@"CTReliableNetworkFallbackSettings");
		id obj = rcls ? [[rcls alloc] init] : @NO;
		if (rcls)
			ct_set(obj, @"isEnabled", @NO);
		invoke_ct_reply_block(replyBlock, NO, obj, NO, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"privacyProxy:completion:"]) {
		Class pcls = NSClassFromString(@"CTPrivacyProxyInfo");
		id obj = pcls ? [[pcls alloc] init] : @{};
		invoke_ct_reply_block(replyBlock, NO, obj, NO, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"copyBundleIdentifier:bundleType:completion:"]) {
		invoke_ct_reply_block(replyBlock, NO, @"com.apple.DefaultCarrier_bundle", YES, 0, nil);
		return YES;
	}
	if ([sname isEqualToString:@"copyBundleVersion:bundleType:completion:"]) {
		invoke_ct_reply_block(replyBlock, NO, @"64.0", YES, 0, nil);
		return YES;
	}
	return NO;
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
	NSString *sname = NSStringFromSelector(anInvocation.selector);
	@try {
		if ([self handleDynamicCTSelector:sname invocation:anInvocation])
			return;
	} @catch (id exc) {
		clog("handleDynamicCTSelector exception (%s): %s",
		     [sname UTF8String], [[exc description] UTF8String]);
	}

	os_unfair_lock_lock(&g_clients_lock);
	BOOL first = ![g_logged_unhandled containsObject:sname];
	if (first)
		[g_logged_unhandled addObject:sname];
	os_unfair_lock_unlock(&g_clients_lock);
	if (first)
		clog("unhandled XPC selector: %s", [sname UTF8String]);

	/* If last parameter is a reply block (@?), invoke it safely so caller never hangs */
	@try {
		NSMethodSignature *sig = anInvocation.methodSignature;
		NSUInteger argc = sig.numberOfArguments;
		if (argc >= 3) {
			const char *lastType = [sig getArgumentTypeAtIndex:argc - 1];
			if (lastType && strncmp(lastType, "@?", 2) == 0) {
				__unsafe_unretained id replyBlock = nil;
				[anInvocation getArgument:&replyBlock atIndex:(NSInteger)(argc - 1)];
				NSError *err = [NSError errorWithDomain:NSPOSIXErrorDomain
								   code:ENOTSUP
							       userInfo:nil];
				invoke_ct_reply_block(replyBlock, NO, nil, NO, 0, err);
			}
		}
	} @catch (id exc) {
		clog("forwardInvocation block reply exception (%s): %s",
		     [sname UTF8String], [[exc description] UTF8String]);
	}
}

@end

/* ---- NSXPCListener Delegate for com.apple.commcenter.coretelephony.xpc ---- */

@interface HotCellularListenerDelegate : NSObject
@end

@implementation HotCellularListenerDelegate

- (BOOL)listener:(id)listener shouldAcceptNewConnection:(HotXPCConnectionSPI *)newConnection
{
	(void)listener;
	@try {
		Class ifcCls = NSClassFromString(@"NSXPCInterface");
		Protocol *expProto = objc_getProtocol("CTXPCServiceInterface");
		Protocol *remProto = objc_getProtocol("CoreTelephonyClientDelegateProxyInterface");
		if (!ifcCls || !expProto) {
			clog("CTXPCServiceInterface protocol missing in runtime!");
			return NO;
		}
		HotXPCInterfaceSPI *expIfc = [(id)ifcCls interfaceWithProtocol:expProto];
		NSSet<Class> *allowed = build_allowed_ct_classes();
		[expIfc setClasses:allowed
		       forSelector:@selector(sendRequest:completionHandler:)
		     argumentIndex:0
			   ofReply:NO];
		[expIfc setClasses:allowed
		       forSelector:@selector(sendRequest:completionHandler:)
		     argumentIndex:0
			   ofReply:YES];
		static const char * const extraReplySels[] = {
			"copyCarrierBundleValue:keyHierarchy:bundleType:completion:",
			"copyCarrierBundleValueWithDefault:keyHierarchy:bundleType:completion:",
			"context:getSystemCapabilities:",
			"context:getSystemCapabilitiesWithCompletion:",
			"getCallCapabilities:completion:",
		};
		for (size_t si = 0; si < sizeof(extraReplySels) / sizeof(extraReplySels[0]); si++) {
			SEL s = sel_registerName(extraReplySels[si]);
			struct objc_method_description md = find_proto_method(expProto, s, [NSMutableSet set]);
			if (md.types) {
				@try {
					[expIfc setClasses:allowed forSelector:s argumentIndex:0 ofReply:YES];
				} @catch (id exc) {
					(void)exc;
				}
			}
		}

		HotXPCInterfaceSPI *remIfc = remProto ? [(id)ifcCls interfaceWithProtocol:remProto] : nil;

		HotCellularXPCService *svc = [[HotCellularXPCService alloc] init];
		svc.connection = newConnection;
		newConnection.exportedInterface = expIfc;
		newConnection.exportedObject = svc;
		if (remIfc)
			newConnection.remoteObjectInterface = remIfc;

		os_unfair_lock_lock(&g_clients_lock);
		[g_xpc_clients addObject:svc];
		os_unfair_lock_unlock(&g_clients_lock);

		__weak HotCellularXPCService *weakSvc = svc;
		int pid = newConnection.processIdentifier;
		newConnection.invalidationHandler = ^{
			HotCellularXPCService *strongSvc = weakSvc;
			if (strongSvc) {
				os_unfair_lock_lock(&g_clients_lock);
				[g_xpc_clients removeObjectIdenticalTo:strongSvc];
				os_unfair_lock_unlock(&g_clients_lock);
			}
		};
		clog("accepted CoreTelephony XPC client pid %d", pid);
		[newConnection resume];
		return YES;
	} @catch (id exc) {
		clog("shouldAcceptNewConnection exception: %s", [[exc description] UTF8String]);
		return NO;
	}
}

@end

/* Push live delegate callbacks to all connected CoreTelephonyClient processes */
static void broadcast_ct_notifications(const struct cellular_state *st, bool sim_changed)
{
	NSArray<HotCellularXPCService *> *clients = nil;
	os_unfair_lock_lock(&g_clients_lock);
	clients = [g_xpc_clients copy];
	os_unfair_lock_unlock(&g_clients_lock);

	id ctx1 = build_slot1_context(st);
	id sigInfo = build_signal_info(st);
	id dispStatus = build_display_status(st);
	id dataStatus = build_data_status(st);
	NSString *simSt = sim_status_string(st);
	NSString *opName = st->operator_name[0] ? [NSString stringWithUTF8String:st->operator_name] : @"";

	for (HotCellularXPCService *svc in clients) {
		if (!svc.registeredNotifications || !svc.connection)
			continue;
		@try {
			HotCTDelegateProxy *proxy = [svc.connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
				(void)e;
			}];
			if (!proxy)
				continue;
			if (sim_changed) {
				[proxy subscriptionInfoDidChange];
				[proxy activeSubscriptionsDidChange];
				if (ctx1)
					[proxy simStatusDidChange:ctx1 status:simSt];
			}
			if (ctx1) {
				if (sigInfo)
					[proxy signalStrengthChanged:ctx1 info:sigInfo];
				[proxy operatorNameChanged:ctx1 name:opName];
				if (dispStatus)
					[proxy displayStatusChanged:ctx1 status:dispStatus];
				if (dataStatus)
					[proxy dataStatus:ctx1 dataStatusInfo:dataStatus];
				[proxy servingNetworkChanged:ctx1];
			}
		} @catch (id exc) {
			(void)exc;
		}
	}

	if (fn_notify_post) {
		if (sim_changed)
			fn_notify_post("com.apple.commcenter.SimStatus.changed");
		fn_notify_post("com.apple.commcenter.Plmn.changed");
	}
}

/*
 * (sweetcelld) the switches changed (Settings, or airplane mode): tell the registered CoreTelephony clients, as
 * CommCenter does. Settings' PSUICoreTelephonyDataCache keeps the value it read once and changes it only on these
 * (seen in SettingsCellularUI: fetchCellularDataEnabled returns early once cellularDataSettingInitialized is set), so
 * without them the switch drew the old value the next time the pane opened.
 */
static void broadcast_data_settings(bool roaming_changed)
{
	NSArray<HotCellularXPCService *> *clients = nil;
	os_unfair_lock_lock(&g_clients_lock);
	clients = [g_xpc_clients copy];
	os_unfair_lock_unlock(&g_clients_lock);
	struct cellular_state st = snapshot_state();
	id ds = build_data_settings();
	id ctx1 = roaming_changed ? build_slot1_context(&st) : nil;
	unsigned told = 0;
	for (HotCellularXPCService *svc in clients) {
		if (!svc.registeredNotifications || !svc.connection)
			continue;
		@try {
			HotCTDelegateProxy *proxy = [svc.connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
				(void)e;
			}];
			if (!proxy)
				continue;
			if (ds)
				[proxy dataSettingsChanged:ds];
			if (ctx1)
				[proxy dataRoamingSettingsChanged:ctx1 status:g_data_roaming];
			told++;
		} @catch (id exc) {
			(void)exc;
		}
	}
	clog("switches sent to %u client(s): Cellular Data %d, Data Roaming %d%s", told, g_cellular_data_enabled ? 1 : 0,
	     g_data_roaming ? 1 : 0, ctx1 ? "" : (roaming_changed ? " (no SIM context for roaming)" : ""));
}

/* ---- Legacy com.apple.commcenter.xpc (CTServerConnection) Listener ---- */

static hot_xpc_t g_legacy_listener;

/* (sweetcelld) what a CTServerConnection packet request carries, for the log (only while /private/var/sweetcell/debug exists) */
static void log_legacy_message(hot_xpc_t msg)
{
	static char *(*fn_copy_desc)(hot_xpc_t);
	if (!fn_copy_desc)
		fn_copy_desc = dlsym(RTLD_DEFAULT, "xpc_copy_description");
	if (!fn_copy_desc)
		return;
	if (!g_debug_log)
		return;
	char *d = fn_copy_desc(msg);
	if (!d)
		return;
	if (!strstr(d, "kPacket")) {    /* (only the packet-data requests: the rest are whois/registrations) */
		free(d);
		return;
	}
	if (!strstr(d, "Number") && !strstr(d, "number"))
		clog("CTServerConnection message: %.600s", d);
	else
		clog("CTServerConnection message with a number in it (not logged)");
	free(d);
}

/*
 * (sweetcelld) the data switches over CTServerConnection, as Settings uses them on iOS 26 (seen in its messages): a
 * kPacketGetProperty request names the properties it wants (kEnableCellularData, kCellularDataEnabled,
 * kCellularDataCapable, kAirplaneMode, each with a placeholder value); a kPacketSet... request carries the new value.
 * True if the message was one of those (the reply then has the properties).
 */
static const char * const g_data_keys[] = { "kEnableCellularData", "kCellularDataEnabled" };
static const char * const g_roam_keys[] = { "kEnableDataRoaming", "kDataRoamingEnabled", "kInternationalDataRoaming",
					     "kInternationalDataAccess" };

static bool legacy_packet_property(hot_xpc_t msg, hot_xpc_t reply, const char *req)
{
	static bool (*fn_get_bool)(hot_xpc_t, const char *);
	static int64_t (*fn_get_int64)(hot_xpc_t, const char *);
	if (!fn_get_bool)
		fn_get_bool = dlsym(RTLD_DEFAULT, "xpc_dictionary_get_bool");
	if (!fn_get_int64)
		fn_get_int64 = dlsym(RTLD_DEFAULT, "xpc_dictionary_get_int64");
	if (!req || strncmp(req, "kPacket", 7) != 0 || !fn_xpc_dict_get_value || !fn_get_bool || !fn_get_int64)
		return false;
	bool set = strstr(req, "Set") != NULL;
	bool changed = false, roam_changed = false;
	for (size_t i = 0; i < sizeof(g_data_keys) / sizeof(g_data_keys[0]); i++) {
		if (!fn_xpc_dict_get_value(msg, g_data_keys[i]))
			continue;
		if (set) {
			bool v = fn_get_bool(msg, g_data_keys[i]) || fn_get_int64(msg, g_data_keys[i]) != 0;
			if (v != g_cellular_data_enabled) {
				g_cellular_data_enabled = v;
				changed = true;
				clog("Settings toggled Cellular Data -> %d (%s)", v ? 1 : 0, req);
			}
		}
		/* kEnableCellularData as Settings sends it (int64), kCellularDataEnabled as a bool (GetCellularDataSettings) */
		if (i == 0)
			fn_xpc_dict_set_int64(reply, g_data_keys[i], g_cellular_data_enabled ? 1 : 0);
		else
			fn_xpc_dict_set_bool(reply, g_data_keys[i], g_cellular_data_enabled);
	}
	for (size_t i = 0; i < sizeof(g_roam_keys) / sizeof(g_roam_keys[0]); i++) {
		if (!fn_xpc_dict_get_value(msg, g_roam_keys[i]))
			continue;
		if (set) {
			bool v = fn_get_bool(msg, g_roam_keys[i]) || fn_get_int64(msg, g_roam_keys[i]) != 0;
			if (v != g_data_roaming) {
				g_data_roaming = v;
				changed = roam_changed = true;
				clog("Settings toggled Data Roaming -> %d (%s)", v ? 1 : 0, req);
			}
		}
		fn_xpc_dict_set_bool(reply, g_roam_keys[i], g_data_roaming);
	}
	if (fn_xpc_dict_get_value(msg, "kCellularDataCapable"))
		fn_xpc_dict_set_bool(reply, "kCellularDataCapable", true);
	if (fn_xpc_dict_get_value(msg, "kAirplaneMode"))
		fn_xpc_dict_set_bool(reply, "kAirplaneMode", g_airplane_mode);
	if (set && !changed)
		clog("CTServerConnection %s: nothing changed (Cellular Data %d, Data Roaming %d)", req, g_cellular_data_enabled ? 1 : 0,
		     g_data_roaming ? 1 : 0);
	if (changed) {
		save_settings();
		broadcast_data_settings(roam_changed);
		follow_switches();
	}
	return true;
}

static void handle_legacy_xpc_dict(hot_xpc_t peer, hot_xpc_t msg)
{
	log_legacy_message(msg);
	if (fn_xpc_dict_get_string) {
		const char *prog = fn_xpc_dict_get_string(msg, "kProgName");
		if (prog && prog[0])
			clog("CTServerConnection whois from '%s'", prog);
	}
	if (!fn_xpc_dict_create_reply || !fn_xpc_conn_send)
		return;
	hot_xpc_t reply = fn_xpc_dict_create_reply(msg);
	if (!reply)
		return; /* One-way notification/registration message without reply port */

	struct cellular_state st = snapshot_state();
	fn_xpc_dict_set_int64(reply, "kPosixError", 0);
	fn_xpc_dict_set_int64(reply, "kMachError", 0);
	(void)legacy_packet_property(msg, reply, fn_xpc_dict_get_string ? fn_xpc_dict_get_string(msg, "kRequest") : NULL);
	fn_xpc_dict_set_string(reply, "kCTSIMSupportSIMStatus", [sim_status_string(&st) UTF8String]);
	fn_xpc_dict_set_string(reply, "kCTRegistrationStatus", [reg_status_string(&st) UTF8String]);
	if (st.operator_name[0])
		fn_xpc_dict_set_string(reply, "kCTRegistrationOperatorName", st.operator_name);
	fn_xpc_dict_set_bool(reply, "kAutoReadOutEnabled", false);
	fn_xpc_dict_set_bool(reply, "kSmsCellBroadcastEnabled", false);

	/* Populate kCTCopySystemCapabilities / kCTCapabilityPhoneServices */
	if (fn_xpc_dict_create && fn_xpc_dict_set_value) {
		hot_xpc_t phone_caps = fn_xpc_dict_create(NULL, NULL, 0);
		hot_xpc_t sys_caps = fn_xpc_dict_create(NULL, NULL, 0);
		if (phone_caps && sys_caps) {
			fn_xpc_dict_set_bool(phone_caps, "kCTCapabilityAgent", true);
			fn_xpc_dict_set_bool(phone_caps, "kCTCapabilityAgent2", true);
			fn_xpc_dict_set_bool(phone_caps, "kCTCallManagementIsPhoneServicesActive", false);
			fn_xpc_dict_set_bool(phone_caps, "kCTCallManagementPhoneServicesCSCallingAvailable", false);
			fn_xpc_dict_set_bool(phone_caps, "kCTCallManagementPhoneServicesVoLTECallingAvailable", false);
			fn_xpc_dict_set_bool(phone_caps, "kCTCallManagementEmergencyWifiAllowed", false);
			fn_xpc_dict_set_bool(phone_caps, "kCTCallManagementEmergencyWifiCallCapable", false);
			fn_xpc_dict_set_value(sys_caps, "kCTCapabilityPhoneServices", phone_caps);
			fn_xpc_dict_set_value(reply, "kCTCapabilityPhoneServices", phone_caps);
			fn_xpc_dict_set_value(reply, "kCTSystemCapabilities", sys_caps);
			fn_xpc_dict_set_value(reply, "kCTCopySystemCapabilities", sys_caps);
		}
		if (phone_caps && fn_xpc_release)
			fn_xpc_release(phone_caps);
		if (sys_caps && fn_xpc_release)
			fn_xpc_release(sys_caps);
	}

	/* Privacy-safe emergency number check in RAM ONLY (never log digits) */
	if (fn_xpc_dict_get_string) {
		static const char * const num_keys[] = {
			"kCTEmergencyNumber", "kCTCallNumber", "PhoneNumber", "number", "kNumber"
		};
		const char *num = NULL;
		for (size_t i = 0; i < sizeof(num_keys) / sizeof(num_keys[0]); i++) {
			num = fn_xpc_dict_get_string(msg, num_keys[i]);
			if (num && num[0])
				break;
		}
		const char *req_cmd = fn_xpc_dict_get_string(msg, "request");
		if (!req_cmd)
			req_cmd = fn_xpc_dict_get_string(msg, "kRequest");
		bool is_emerg_req = (num != NULL) ||
				    (req_cmd && strstr(req_cmd, "Emergency") != NULL) ||
				    (fn_xpc_dict_get_value &&
				     fn_xpc_dict_get_value(msg, "kCTCopyIsEmergencyNumber") != NULL);
		if (is_emerg_req) {
			bool em = is_emergency_cstr(num);
			fn_xpc_dict_set_bool(reply, "kCTIsEmergencyNumber", em);
			fn_xpc_dict_set_bool(reply, "isEmergencyNumber", em);
			fn_xpc_dict_set_bool(reply, "kIsEmergencyNumber", em);
		}
	}

	fn_xpc_conn_send(peer, reply);
	if (fn_xpc_release)
		fn_xpc_release(reply);
}

static void start_legacy_commcenter_xpc(dispatch_queue_t q)
{
	if (!fn_xpc_conn_create_mach || !fn_xpc_conn_set_handler || !fn_xpc_conn_resume) {
		clog("libxpc mach service symbols unavailable");
		return;
	}
	/* XPC_CONNECTION_MACH_SERVICE_LISTENER = (1ULL << 0) */
	hot_xpc_t listener = fn_xpc_conn_create_mach("com.apple.commcenter.xpc", q, 1ULL);
	if (!listener) {
		clog("failed to create com.apple.commcenter.xpc listener");
		return;
	}
	g_legacy_listener = listener;
	fn_xpc_conn_set_handler(listener, ^(hot_xpc_t event) {
		if (!event || !fn_xpc_get_type)
			return;
		const void *t = fn_xpc_get_type(event);
		if (t == sym_xpc_type_connection) {
			hot_xpc_t peer = event;
			if (fn_xpc_retain)
				fn_xpc_retain(peer);
			if (fn_xpc_conn_set_target_queue)
				fn_xpc_conn_set_target_queue(peer, q);
			fn_xpc_conn_set_handler(peer, ^(hot_xpc_t msg) {
				if (!msg)
					return;
				const void *mt = fn_xpc_get_type(msg);
				if (mt == sym_xpc_type_dictionary) {
					handle_legacy_xpc_dict(peer, msg);
				} else if (msg == sym_xpc_error_conn_invalid) {
					if (fn_xpc_release)
						fn_xpc_release(peer);
				}
			});
			fn_xpc_conn_resume(peer);
		}
	});
	fn_xpc_conn_resume(listener);
	clog("listening on com.apple.commcenter.xpc (CTServerConnection)");
}

/* ---- QMI / QRTR Background Engine ---- */

static dispatch_queue_t g_qmi_queue;
static dispatch_source_t g_qrtr_read_src;
static dispatch_source_t g_poll_timer;
static struct qmi_ctx g_qmi;
static unsigned g_poll_ticks;
static uint64_t g_last_online_try_ms;
static int g_online_attempts;
static uint8_t g_last_logged_dms_mode = 0xfe;
static uint64_t g_last_wds_try_ms;

static uint64_t cell_mono_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)(ts.tv_nsec / 1000000ull);
}

static uint32_t core_srv_mask(const struct qmi_ctx *ctx)
{
	uint32_t m = 0;
	if (qmi_has_service(ctx, QMI_SVC_DMS))   m |= QMI_IND_MASK_DMS;
	if (qmi_has_service(ctx, QMI_SVC_UIM))   m |= QMI_IND_MASK_UIM;
	if (qmi_has_service(ctx, QMI_SVC_NAS))   m |= QMI_IND_MASK_NAS;
	if (qmi_has_service(ctx, QMI_SVC_WDS))   m |= QMI_IND_MASK_WDS;
	if (qmi_has_service(ctx, QMI_SVC_VOICE)) m |= QMI_IND_MASK_VOICE;
	return m;
}

static void try_connect_and_sync(void);
static void commit_and_publish(const struct cellular_state *next, bool force_broadcast);

static void commit_and_publish(const struct cellular_state *next, bool force_broadcast)
{
	os_unfair_lock_lock(&g_state_lock);
	bool prev_sim = g_state.sim_present;
	char prev_sim_st[32], prev_op[64], prev_mcc[8], prev_reg[32], prev_rat[16], prev_call_st[24];
	int prev_bars = g_state.bars_0_to_4;
	bool prev_ps = g_state.ps_attached;
	bool prev_data = g_state.data_connected;
	uint8_t prev_dms = g_state.dms_mode_raw;
	uint16_t prev_rej = g_state.last_reject_cause;
	uint32_t prev_calls = g_state.active_calls;
	snprintf(prev_sim_st, sizeof(prev_sim_st), "%s", g_state.sim_state);
	snprintf(prev_op, sizeof(prev_op), "%s", g_state.operator_name);
	snprintf(prev_mcc, sizeof(prev_mcc), "%s", g_state.mcc);
	snprintf(prev_reg, sizeof(prev_reg), "%s", g_state.reg_state);
	snprintf(prev_rat, sizeof(prev_rat), "%s", g_state.rat);
	snprintf(prev_call_st, sizeof(prev_call_st), "%s", g_state.last_call_state);
	g_state = *next;
	os_unfair_lock_unlock(&g_state_lock);

	bool sim_changed = force_broadcast || (prev_sim != next->sim_present) ||
			   (strcmp(prev_sim_st, next->sim_state) != 0);
	bool op_or_mcc_changed = (strcmp(prev_op, next->operator_name) != 0) ||
				 (strcmp(prev_mcc, next->mcc) != 0);
	bool any_changed = sim_changed ||
			   (prev_dms != next->dms_mode_raw) ||
			   (prev_rej != next->last_reject_cause) ||
			   (prev_calls != next->active_calls) ||
			   (strcmp(prev_call_st, next->last_call_state) != 0) ||
			   (prev_bars != next->bars_0_to_4) ||
			   (prev_ps != next->ps_attached) ||
			   (prev_data != next->data_connected) ||
			   op_or_mcc_changed ||
			   (strcmp(prev_reg, next->reg_state) != 0) ||
			   (strcmp(prev_rat, next->rat) != 0);

	if (any_changed) {
		/* (no operator name, country code or addresses in the log) */
		clog("state: sim=%s(slot %d,%s) mode=%s(%u,off=0x%04x,hw=%d) reg=%s(rej=%u) rat=%s plmn %s, operator name %s, rsrp=%d bars=%d/4 cs=%d ps=%d data=%d",
		     next->sim_present ? "yes" : "no",
		     next->sim_slot, next->app_state, next->radio_mode, next->dms_mode_raw,
		     next->dms_offline_reason, next->dms_hw_restricted ? 1 : 0,
		     next->reg_state, next->last_reject_cause, next->rat, next->mcc[0] ? "known" : "unknown",
		     next->operator_name[0] ? "known" : "unknown", next->has_rsrp ? next->rsrp_dbm : 0,
		     next->bars_0_to_4, next->cs_attached ? 1 : 0,
		     next->ps_attached ? 1 : 0,
		     next->data_connected ? 1 : 0);
		publish_system_status(next);
		broadcast_ct_notifications(next, sim_changed);
	}
}

static void on_qmi_indication(struct qmi_ctx *ctx, uint32_t service, uint16_t msg_id,
			      const uint8_t *tlvs, size_t tlv_len, void *user)
{
	(void)user;
	struct cellular_state cur = snapshot_state();
	if (qmi_apply_indication(ctx, &cur, service, msg_id, tlvs, tlv_len)) {
		commit_and_publish(&cur, service == QMI_SVC_UIM);
	}
}

static void teardown_qrtr_source(void)
{
	g_last_online_try_ms = 0;
	g_online_attempts = 0;
	g_last_logged_dms_mode = 0xfe;
	if (g_qrtr_read_src) {
		dispatch_source_cancel(g_qrtr_read_src);
		g_qrtr_read_src = nil;
	} else {
		qmi_close(&g_qmi);
	}
}

static void ensure_dms_online_if_needed(struct cellular_state *cur)
{
	if (!qmi_has_service(&g_qmi, QMI_SVC_DMS))
		return;
	if (cur->dms_mode_raw == 0) {
		g_online_attempts = 0;
		g_last_logged_dms_mode = 0;
		return;
	}
	if (cur->dms_mode_raw == 0xff)
		return;

	if (g_last_logged_dms_mode != cur->dms_mode_raw) {
		g_last_logged_dms_mode = cur->dms_mode_raw;
		clog("DMS non-online: mode='%s' (%u) offline_reason=0x%04x(valid=%d) hw_restricted=%d",
		     cur->radio_mode, cur->dms_mode_raw,
		     cur->dms_offline_reason, cur->has_dms_offline_reason ? 1 : 0,
		     cur->dms_hw_restricted ? 1 : 0);
	}

	if (g_airplane_mode || g_online_attempts >= 6)
		return;
	uint64_t now_ms = cell_mono_ms();
	if (g_last_online_try_ms != 0 && (now_ms - g_last_online_try_ms) < 10000ull)
		return;

	g_online_attempts++;
	g_last_online_try_ms = now_ms;
	uint16_t qerr = 0;
	int mrc = qmi_dms_set_operating_mode_ex(&g_qmi, 0x00, &qerr);
	clog("QMI_DMS_SET_OPERATING_MODE(ONLINE) attempt %d/6 from '%s'(%u, off_reason=0x%04x, hw=%d) -> rc=%d qmi_err=0x%04x",
	     g_online_attempts, cur->radio_mode, cur->dms_mode_raw,
	     cur->dms_offline_reason, cur->dms_hw_restricted ? 1 : 0, mrc, qerr);
	if (mrc != 0 && cur->dms_mode_raw == 6) {
		/* persistent_low_power sometimes requires transition via LOW_POWER (1) first */
		uint16_t lperr = 0;
		int lprc = qmi_dms_set_operating_mode_ex(&g_qmi, 0x01, &lperr);
		if (lprc == 0) {
			usleep(100000);
			mrc = qmi_dms_set_operating_mode_ex(&g_qmi, 0x00, &qerr);
			clog("QMI_DMS_SET_OPERATING_MODE(LP->ONLINE) retry -> rc=%d qmi_err=0x%04x", mrc, qerr);
		}
	}
	if (mrc == 0) {
		usleep(200000);
		(void)qmi_poll_all(&g_qmi, cur, !cur->modem_rev[0]);
		if (cur->dms_mode_raw == 0)
			g_online_attempts = 0;
	}
}

/* ---- Mobile data through the IPA (Bergamota: xnu 3073 kern.sweet_ipa, rmnet0) ---- */

static bool g_data_up;                  /* our session is up, rmnet0 has its address, configd has the service */
static bool g_dpm_open;
static uint32_t g_data_handle;
static uint64_t g_data_next_try_ms;
static unsigned g_data_failures;

typedef const struct __SCDynamicStore *HotSCDynamicStoreRef;
static HotSCDynamicStoreRef (*fn_SCDynamicStoreCreate)(CFAllocatorRef, CFStringRef, void *, void *);
static Boolean (*fn_SCDynamicStoreSetValue)(HotSCDynamicStoreRef, CFStringRef, CFPropertyListRef);
static Boolean (*fn_SCDynamicStoreRemoveValue)(HotSCDynamicStoreRef, CFStringRef);
static HotSCDynamicStoreRef g_sc;

static void load_settings(void)
{
	FILE *f = fopen(SWEETCELL_SETTINGS, "r");
	if (!f)
		return;
	char line[80];
	while (fgets(line, sizeof(line), f)) {
		if (!strncmp(line, "cellular_data=", 14))
			g_cellular_data_enabled = atoi(line + 14) != 0;
		else if (!strncmp(line, "data_roaming=", 13))
			g_data_roaming = atoi(line + 13) != 0;
	}
	fclose(f);
}

static void save_settings(void)
{
	FILE *f = fopen(SWEETCELL_SETTINGS ".new", "w");
	if (!f)
		return;
	fprintf(f, "cellular_data=%d\ndata_roaming=%d\n", g_cellular_data_enabled ? 1 : 0, g_data_roaming ? 1 : 0);
	fclose(f);
	(void)rename(SWEETCELL_SETTINGS ".new", SWEETCELL_SETTINGS);
}

static void sc_load(void)
{
	if (g_sc)
		return;
	void *h = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW);
	if (!h)
		return;
	fn_SCDynamicStoreCreate = dlsym(h, "SCDynamicStoreCreate");
	fn_SCDynamicStoreSetValue = dlsym(h, "SCDynamicStoreSetValue");
	fn_SCDynamicStoreRemoveValue = dlsym(h, "SCDynamicStoreRemoveValue");
	if (fn_SCDynamicStoreCreate && fn_SCDynamicStoreSetValue && fn_SCDynamicStoreRemoveValue)
		g_sc = fn_SCDynamicStoreCreate(NULL, CFSTR("sweetcelld"), NULL, NULL);
	if (!g_sc)
		clog("SCDynamicStore unavailable: rmnet0 will not be published to configd");
}

/*
 * rmnet0 as a configd service (as sweetnetcfg does for ue0). While Wi-Fi has an IPv4 address: no PrimaryRank, and Wi-Fi,
 * in the service order, comes first (seen: en0 primary, rmnet0 scoped). Without Wi-Fi: PrimaryRank First, so that the USB
 * link's service (ue0, routed through the Mac in development) does not carry the phone's traffic instead of cellular.
 */
static char g_pub_addr[20], g_pub_mask[20], g_pub_router[20], g_pub_dns1[20], g_pub_dns2[20];
static int g_pub_first = -1;            /* the rank published: -1 none, 0 default, 1 First */

static bool wifi_has_ipv4(void)
{
	struct ifaddrs *ifa = NULL;
	bool up = false;
	if (getifaddrs(&ifa) != 0)
		return true;            /* (unknown: as if Wi-Fi were there) */
	for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
		if (i->ifa_name && !strcmp(i->ifa_name, "en0") && i->ifa_addr && i->ifa_addr->sa_family == AF_INET &&
		    (i->ifa_flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING))
			up = true;
	}
	freeifaddrs(ifa);
	return up;
}

static void configd_publish(const char *addr, const char *mask, const char *router, const char *dns1, const char *dns2)
{
	snprintf(g_pub_addr, sizeof(g_pub_addr), "%s", addr);
	snprintf(g_pub_mask, sizeof(g_pub_mask), "%s", mask);
	snprintf(g_pub_router, sizeof(g_pub_router), "%s", router);
	snprintf(g_pub_dns1, sizeof(g_pub_dns1), "%s", dns1 ? dns1 : "");
	snprintf(g_pub_dns2, sizeof(g_pub_dns2), "%s", dns2 ? dns2 : "");
	bool first = !wifi_has_ipv4();
	sc_load();
	if (!g_sc)
		return;
	NSString *base = @"State:/Network/Service/" SWEET_DATA_SERVICE;
	NSMutableArray *dns = [NSMutableArray array];
	if (dns1 && dns1[0])
		[dns addObject:@(dns1)];
	if (dns2 && dns2[0])
		[dns addObject:@(dns2)];
	NSDictionary *svc = first ? @{ @"InterfaceName": @"rmnet0", @"PrimaryRank": @"First" } : @{ @"InterfaceName": @"rmnet0" };
	NSDictionary *v4 = @{ @"Addresses": @[ @(addr) ], @"SubnetMasks": @[ @(mask) ], @"Router": @(router),
			      @"InterfaceName": @"rmnet0" };
	NSDictionary *d = @{ @"ServerAddresses": dns };
	Boolean ok = fn_SCDynamicStoreSetValue(g_sc, (__bridge CFStringRef)base, (__bridge CFPropertyListRef)svc) &&
		     fn_SCDynamicStoreSetValue(g_sc, (__bridge CFStringRef)[base stringByAppendingString:@"/IPv4"],
					       (__bridge CFPropertyListRef)v4) &&
		     fn_SCDynamicStoreSetValue(g_sc, (__bridge CFStringRef)[base stringByAppendingString:@"/DNS"],
					       (__bridge CFPropertyListRef)d);
	clog("configd: rmnet0 service %s (%lu DNS servers, %s)", ok ? "published" : "NOT published", (unsigned long)dns.count,
	     first ? "primary: no Wi-Fi" : "below Wi-Fi");
	g_pub_first = ok ? (first ? 1 : 0) : -1;
}

/* Wi-Fi came or went: the rank follows (from the QMI queue, every poll and every indication tick) */
static void configd_follow_wifi(void)
{
	if (g_pub_first < 0 || !g_pub_addr[0])
		return;
	int want = wifi_has_ipv4() ? 0 : 1;
	if (want != g_pub_first)
		configd_publish(g_pub_addr, g_pub_mask, g_pub_router, g_pub_dns1, g_pub_dns2);
}

static void configd_remove(void)
{
	sc_load();
	if (!g_sc)
		return;
	NSString *base = @"State:/Network/Service/" SWEET_DATA_SERVICE;
	fn_SCDynamicStoreRemoveValue(g_sc, (__bridge CFStringRef)[base stringByAppendingString:@"/IPv4"]);
	fn_SCDynamicStoreRemoveValue(g_sc, (__bridge CFStringRef)[base stringByAppendingString:@"/DNS"]);
	fn_SCDynamicStoreRemoveValue(g_sc, (__bridge CFStringRef)base);
	g_pub_first = -1;
	g_pub_addr[0] = '\0';
}

/* the IPA's stages (xnu 3073) up to 6 (rmnet0), from where they stand */
static bool ipa_bring_up(void)
{
	int s = -1;
	size_t n = sizeof(s);
	if (sysctlbyname("kern.sweet_ipa", &s, &n, NULL, 0) != 0) {
		clog("no kern.sweet_ipa: this kernel has no IPA (xnu 3073 and later)");
		return false;
	}
	for (int k = s + 1; k <= 6; k++) {
		if (sysctlbyname("kern.sweet_ipa", NULL, NULL, &k, sizeof(k)) != 0) {
			clog("IPA stage %d failed (%s); kern.sweet_ipa_status has the reason", k, strerror(errno));
			return false;
		}
		clog("IPA stage %d done", k);
	}
	return true;
}

static void wr_u32(uint8_t *p, uint32_t v)
{
	memcpy(p, &v, 4);
}

static uint32_t tlv_u32(const uint8_t *rsp, size_t len, uint8_t t)
{
	uint16_t l = 0;
	const uint8_t *v = qmi_tlv_find(rsp, len, t, &l);
	uint32_t x = 0;
	if (v && l >= 4)
		memcpy(&x, v, 4);
	return x;
}

static void fmt_v4(char *dst, size_t cap, uint32_t le)
{
	snprintf(dst, cap, "%u.%u.%u.%u", le >> 24, (le >> 16) & 0xff, (le >> 8) & 0xff, le & 0xff);
}

static void save_handle(uint32_t h)
{
	if (!h) {
		(void)unlink(SWEETCELL_HANDLE);
		return;
	}
	FILE *f = fopen(SWEETCELL_HANDLE, "w");
	if (f) {
		fprintf(f, "%u\n", h);
		fclose(f);
	}
}

/* the session's settings to rmnet0 and configd; true when it has an address */
static bool data_apply_settings(struct cellular_state *st)
{
	uint8_t req[16], rsp[512];
	size_t rl = 0, rsp_len = 0;
	uint8_t mask4[4];
	wr_u32(mask4, 0x2310u);         /* DNS, IP address, gateway (with the mask), MTU */
	qmi_tlv_put(req, sizeof(req), &rl, 0x10, mask4, 4);
	if (qmi_request(&g_qmi, QMI_SVC_WDS, QMI_WDS_GET_RUNTIME_SETTINGS, req, rl, rsp, sizeof(rsp), &rsp_len, 2000) != 0 ||
	    qmi_check_result(rsp, rsp_len, NULL) != 0) {
		clog("WDS runtime settings: not given");
		return false;
	}
	uint32_t ip = tlv_u32(rsp, rsp_len, 0x1e), gw = tlv_u32(rsp, rsp_len, 0x20), mk = tlv_u32(rsp, rsp_len, 0x21);
	uint32_t d1 = tlv_u32(rsp, rsp_len, 0x15), d2 = tlv_u32(rsp, rsp_len, 0x16), mtu = tlv_u32(rsp, rsp_len, 0x29);
	if (!ip || !gw || !mk) {
		clog("WDS runtime settings: no IPv4 address yet");
		return false;
	}
	if (mtu < 576 || mtu > 1500)
		mtu = 1500;
	char a[20], g[20], k[20], s1[20] = "", s2[20] = "", sess[96];
	fmt_v4(a, sizeof(a), ip);
	fmt_v4(g, sizeof(g), gw);
	fmt_v4(k, sizeof(k), mk);
	if (d1)
		fmt_v4(s1, sizeof(s1), d1);
	if (d2)
		fmt_v4(s2, sizeof(s2), d2);
	snprintf(sess, sizeof(sess), "%s %s %s %u", a, k, g, mtu);
	if (sysctlbyname("kern.sweet_ipa_session", NULL, NULL, sess, strlen(sess)) != 0) {
		clog("rmnet0: the session's address not taken (%s)", strerror(errno));
		return false;
	}
	configd_publish(a, k, g, s1, s2);
	snprintf(st->data_ip, sizeof(st->data_ip), "%s", a);
	snprintf(st->data_netmask, sizeof(st->data_netmask), "%s", k);
	snprintf(st->data_gateway, sizeof(st->data_gateway), "%s", g);
	snprintf(st->data_dns1, sizeof(st->data_dns1), "%s", s1);
	snprintf(st->data_dns2, sizeof(st->data_dns2), "%s", s2);
	st->data_mtu = mtu;
	st->wds_ip_family = 4;
	clog("rmnet0 up with the session's IPv4 address (MTU %u)", mtu);
	return true;
}

/* WDS Get Packet Service Status: 2 connected, 1 disconnected, 0 unknown */
static int wds_status(void)
{
	uint8_t rsp[64];
	size_t rsp_len = 0;
	if (qmi_request(&g_qmi, QMI_SVC_WDS, QMI_WDS_GET_PKT_SRVC_STATUS, NULL, 0, rsp, sizeof(rsp), &rsp_len, 2000) != 0 ||
	    qmi_check_result(rsp, rsp_len, NULL) != 0)
		return 0;
	uint16_t l = 0;
	const uint8_t *v = qmi_tlv_find(rsp, rsp_len, 0x01, &l);
	return v && l >= 1 ? v[0] : 0;
}

/* WDS Reset: ends the sessions of our client (the kernel's port) when no handle is known (tried: connected -> disconnected) */
static void wds_reset(void)
{
	uint8_t rsp[64];
	size_t rsp_len = 0;
	(void)qmi_request(&g_qmi, QMI_SVC_WDS, 0x0000, NULL, 0, rsp, sizeof(rsp), &rsp_len, 2000);
}

static bool data_up(struct cellular_state *st)
{
	uint8_t req[64], rsp[512], ep[8];
	size_t rl = 0, rsp_len = 0;
	uint16_t qerr = 0;

	if (!ipa_bring_up())
		return false;
	wr_u32(ep, 4);                  /* the embedded data port (the IPA), interface 1 */
	wr_u32(ep + 4, 1);
	if (!g_dpm_open) {
		uint8_t port[17];
		port[0] = 1;
		memcpy(port + 1, ep, 8);
		wr_u32(port + 9, 2);    /* the modem receives on IPA endpoint 2 (ours to it) */
		wr_u32(port + 13, 10);  /* and sends on 10 (ours from it) */
		qmi_tlv_put(req, sizeof(req), &rl, 0x11, port, sizeof(port));
		if (qmi_request(&g_qmi, QMI_SVC_DPM, QMI_DPM_OPEN_PORT, req, rl, rsp, sizeof(rsp), &rsp_len, 2000) != 0 ||
		    qmi_check_result(rsp, rsp_len, &qerr) != 0) {
			/* (open already, from an earlier run or by hand: WDA and the bind tell whether the port is there) */
			clog("DPM open port: error 0x%04x (going on)", qerr);
		}
		g_dpm_open = true;
	}
	uint8_t v[4];
	rl = 0;
	wr_u32(v, 2);
	qmi_tlv_put(req, sizeof(req), &rl, 0x11, v, 4);         /* raw IP */
	wr_u32(v, 8);
	qmi_tlv_put(req, sizeof(req), &rl, 0x12, v, 4);         /* QMAPv4 up */
	qmi_tlv_put(req, sizeof(req), &rl, 0x13, v, 4);         /* and down */
	wr_u32(v, 10);
	qmi_tlv_put(req, sizeof(req), &rl, 0x15, v, 4);         /* 10 packets */
	wr_u32(v, 8192);
	qmi_tlv_put(req, sizeof(req), &rl, 0x16, v, 4);         /* or 8 KB per downlink aggregate */
	qmi_tlv_put(req, sizeof(req), &rl, 0x17, ep, 8);
	if (qmi_request(&g_qmi, QMI_SVC_WDA, QMI_WDA_SET_DATA_FORMAT, req, rl, rsp, sizeof(rsp), &rsp_len, 2000) != 0 ||
	    qmi_check_result(rsp, rsp_len, &qerr) != 0) {
		clog("WDA data format refused (error 0x%04x)", qerr);
		return false;
	}
	uint8_t mux = 1, fam = 4;
	rl = 0;
	qmi_tlv_put(req, sizeof(req), &rl, 0x10, ep, 8);
	qmi_tlv_put(req, sizeof(req), &rl, 0x11, &mux, 1);
	if (qmi_request(&g_qmi, QMI_SVC_WDS, 0x00a2 /* Bind Mux Data Port */, req, rl, rsp, sizeof(rsp), &rsp_len, 2000) != 0 ||
	    qmi_check_result(rsp, rsp_len, &qerr) != 0)
		clog("WDS bind mux 1: error 0x%04x (going on)", qerr);
	rl = 0;
	qmi_tlv_put(req, sizeof(req), &rl, 0x01, &fam, 1);
	(void)qmi_request(&g_qmi, QMI_SVC_WDS, QMI_WDS_SET_IP_FAMILY_PREF, req, rl, rsp, sizeof(rsp), &rsp_len, 2000);
	uint32_t handle = 0;
	if (wds_status() == 2) {
		clog("WDS: a session of ours is up already: taken over (no handle: ended by WDS Reset)");
		goto adopted;
	}
	rl = 0;
	qmi_tlv_put(req, sizeof(req), &rl, 0x19, &fam, 1);
	if (qmi_request(&g_qmi, QMI_SVC_WDS, QMI_WDS_START_NET_IFACE, req, rl, rsp, sizeof(rsp), &rsp_len, 5000) != 0) {
		/* the kernel waits 5 s; the network may take longer: the session can still come up */
		for (int t = 0; t < 20 && wds_status() != 2; t++)
			usleep(500000);
		if (wds_status() != 2) {
			clog("WDS start: no answer, and no session after 10 s");
			return false;
		}
		clog("WDS start: answered late, the session is up (no handle: ended by WDS Reset)");
		goto adopted;
	}
	handle = tlv_u32(rsp, rsp_len, 0x01);
	if (qmi_check_result(rsp, rsp_len, &qerr) != 0 && qerr == 0x1a && wds_status() == 2) {
		clog("WDS start: no effect, a session is up already: taken over");
		goto adopted;
	}
	if (qmi_check_result(rsp, rsp_len, &qerr) != 0) {
		uint16_t l = 0;
		const uint8_t *r = qmi_tlv_find(rsp, rsp_len, 0x11, &l);
		clog("WDS start refused: error 0x%04x, call end reason %u, verbose %u/%u", qerr, tlv_u32(rsp, rsp_len, 0x10) & 0xffff,
		     r && l >= 4 ? (unsigned)(r[0] | r[1] << 8) : 0, r && l >= 4 ? (unsigned)(r[2] | r[3] << 8) : 0);
		return false;
	}
adopted:
	g_data_handle = handle;
	save_handle(handle ? handle : 0xffffffffu);
	st->data_connected = true;
	usleep(300000);
	if (!data_apply_settings(st)) {
		st->data_connected = false;
		return false;
	}
	g_data_up = true;
	clog("data session up (IPv4)");
	return true;
}

static void data_down(struct cellular_state *st, const char *why)
{
	uint8_t req[16], rsp[128];
	size_t rl = 0, rsp_len = 0;
	if (g_data_handle && g_data_handle != 0xffffffffu) {
		uint8_t h[4];
		wr_u32(h, g_data_handle);
		qmi_tlv_put(req, sizeof(req), &rl, 0x01, h, 4);
		(void)qmi_request(&g_qmi, QMI_SVC_WDS, QMI_WDS_STOP_NET_IFACE, req, rl, rsp, sizeof(rsp), &rsp_len, 3000);
	}
	if (wds_status() == 2)
		wds_reset();
	(void)sysctlbyname("kern.sweet_ipa_session", NULL, NULL, "down", 4);
	configd_remove();
	g_data_up = false;
	g_data_handle = 0;
	save_handle(0);
	st->data_connected = false;
	st->data_ip[0] = st->data_netmask[0] = st->data_gateway[0] = st->data_dns1[0] = st->data_dns2[0] = '\0';
	clog("data session down (%s)", why);
}

/* at the first connection: a session a previous run left (its handle saved) is ended, configd's key cleaned */
static void data_adopt_or_clean(void)
{
	FILE *f = fopen(SWEETCELL_HANDLE, "r");
	unsigned h = 0;
	if (f) {
		if (fscanf(f, "%u", &h) != 1)
			h = 0;
		fclose(f);
	}
	configd_remove();
	if (h || wds_status() == 2) {
		struct cellular_state tmp = snapshot_state();
		g_data_handle = h;
		data_down(&tmp, "left by a previous run");
	}
}

/* what the switches, the radio and the registration call for, done: from the QMI queue */
static void data_reconcile(struct cellular_state *st)
{
	bool radio_ok = !g_airplane_mode && st->dms_mode_raw == 0 && st->sim_present && st->reg_state_raw == 1 && st->ps_attached;
	bool want = g_cellular_data_enabled && radio_ok && (!st->roaming || g_data_roaming);
	if (g_data_up && !st->data_connected)
		data_down(st, "the session ended");
	if (!want && g_data_up) {
		data_down(st, !g_cellular_data_enabled ? "Cellular Data off" : (st->roaming && !g_data_roaming) ? "Data Roaming off" :
		    "no service");
		return;
	}
	if (g_data_up)
		configd_follow_wifi();
	if (want && !g_data_up) {
		uint64_t now = cell_mono_ms();
		if (now < g_data_next_try_ms)
			return;
		if (data_up(st)) {
			g_data_failures = 0;
		} else {
			g_data_failures++;
			unsigned shift = g_data_failures < 4 ? g_data_failures : 4;
			g_data_next_try_ms = now + (5000ull << shift);
		}
	}
}

/* a switch changed: act at once, from the QMI queue */
static void follow_switches(void)
{
	if (!g_qmi_queue)
		return;
	dispatch_async(g_qmi_queue, ^{
		struct cellular_state cur = snapshot_state();
		g_data_next_try_ms = 0;
		if (g_qmi.fd >= 0 && modem_settled())
			data_reconcile(&cur);
		commit_and_publish(&cur, false);
	});
}

/*
 * Whether the modem may be switched online and the data path set up. On 2026-11-07 (119c) the modem crashed ("SFR Init:
 * wdog or kernel error suspected") 1 s after the Wi-Fi firmware's service (WLFW, in the modem) appeared, while its memory
 * was being handed over, with this daemon already sending DMS ONLINE: so not before WLFW has been there 30 s (or, with no
 * Wi-Fi firmware at all, 3 minutes after this daemon started). Read-only queries go on before.
 */
static uint64_t g_start_ms;

static bool modem_settled(void)
{
	static uint64_t wlfw_since;
	static bool said;
	uint64_t now = cell_mono_ms();
	if (!wlfw_since && qmi_has_service(&g_qmi, QMI_SVC_WLFW))
		wlfw_since = now;
	bool ok = (wlfw_since && now - wlfw_since >= 30000) || now - g_start_ms >= 180000;
	if (!ok && !said) {
		said = true;
		clog("waiting for the Wi-Fi firmware to settle before switching the radio on");
	} else if (ok && said) {
		said = false;
		clog("the Wi-Fi firmware has settled: radio and data allowed");
	}
	return ok;
}

/*
 * (sweetcelld) Settings shows its Cellular pane only when MobileGestalt answers cellular-data = yes, which it does not on a
 * device tree without a baseband. The answer is kept in MobileGestalt's cache, where a CacheExtra entry keyed
 * base64(md5("MGCopyAnswer" + question))[:22] overrides it (tools/cellular/mg-override.py did it by hand). That cache is
 * written by MobileGestalt itself (on a fresh root, at the first boot; again when it decides it is stale), so a root image
 * cannot carry the entry: put it back whenever the file changes. Apps that read the cache before see it after a restart.
 */
#define MG_CACHE		"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/" \
				"Caches/com.apple.MobileGestalt.plist"
#define MG_CELLULAR_DATA	"L5al7b+7JATD/izSJeH0aQ"        /* base64(md5("MGCopyAnswercellular-data"))[:22] */

static void mg_ensure_cellular_data(void)
{
	static struct timespec seen;
	struct stat sb;
	if (stat(MG_CACHE, &sb) != 0)
		return;                 /* not written yet: the next poll looks again */
	if (sb.st_mtimespec.tv_sec == seen.tv_sec && sb.st_mtimespec.tv_nsec == seen.tv_nsec)
		return;
	seen = sb.st_mtimespec;
	NSData *d = [NSData dataWithContentsOfFile:@MG_CACHE];
	NSPropertyListFormat fmt = NSPropertyListBinaryFormat_v1_0;
	NSMutableDictionary *mg = d ? [NSPropertyListSerialization propertyListWithData:d
			options:NSPropertyListMutableContainersAndLeaves format:&fmt error:nil] : nil;
	if (![mg isKindOfClass:[NSMutableDictionary class]]) {
		clog("MobileGestalt cache unreadable: cellular-data not set");
		return;
	}
	NSMutableDictionary *extra = mg[@"CacheExtra"];
	if (![extra isKindOfClass:[NSMutableDictionary class]]) {
		extra = [NSMutableDictionary dictionary];
		mg[@"CacheExtra"] = extra;
	}
	if ([extra[@MG_CELLULAR_DATA] isEqual:@YES])
		return;
	extra[@MG_CELLULAR_DATA] = @YES;
	NSData *out = [NSPropertyListSerialization dataWithPropertyList:mg format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
	NSString *tmp = @MG_CACHE ".sweetcelld";
	if (!out || ![out writeToFile:tmp atomically:NO] || chown(tmp.UTF8String, sb.st_uid, sb.st_gid) != 0 ||
	    chmod(tmp.UTF8String, sb.st_mode & 07777) != 0 || rename(tmp.UTF8String, MG_CACHE) != 0) {
		clog("MobileGestalt cache: cellular-data NOT set (%s)", strerror(errno));
		unlink(tmp.UTF8String);
		return;
	}
	if (stat(MG_CACHE, &sb) == 0)
		seen = sb.st_mtimespec;
	clog("MobileGestalt cache: cellular-data set to yes (Settings' Cellular pane; apps already running see it after a restart)");
}

static void try_connect_and_sync(void)
{
	bool just_connected = false;
	if (!g_no_xpc)
		mg_ensure_cellular_data();
	if (g_qmi.fd < 0) {
		g_qmi.ind_cb = on_qmi_indication;
		if (qmi_open(&g_qmi, NULL) < 0)
			return;
		just_connected = true;
		g_last_online_try_ms = 0;
		g_online_attempts = 0;
		g_last_logged_dms_mode = 0xfe;
		clog("connected to the kernel's QMI pass-through (kern.sweet_qmi)");
		(void)qmi_sync_servers(&g_qmi, 600);
	}

	/* indications since the last tick, before the state is copied (also drained every second by the indication timer) */
	(void)qmi_drain_rx(&g_qmi, 0);

	/* Dynamically register indications as DMS/UIM/NAS/WDS become available */
	int new_ind = qmi_register_indications(&g_qmi);
	if (new_ind > 0)
		clog("registered QMI indications: +0x%x (mask=0x%x)", new_ind, g_qmi.ind_reg_mask);

	g_poll_ticks++;
	struct cellular_state cur = snapshot_state();
	bool need_full = just_connected || ((g_poll_ticks % 3) == 0) ||
			 !cur.sim_present || (cur.dms_mode_raw != 0) ||
			 !cur.modem_rev[0] || !qmi_has_service(&g_qmi, QMI_SVC_NAS);
	if (need_full) {
		(void)qmi_poll_all(&g_qmi, &cur, just_connected || !cur.modem_rev[0]);
	} else {
		(void)qmi_poll_fast(&g_qmi, &cur);
	}

	/* Ensure DMS operating mode reaches ONLINE when AirplaneMode is off (once the Wi-Fi firmware has settled) */
	bool settled = modem_settled();
	if (settled)
		ensure_dms_online_if_needed(&cur);

	/* Re-run indication registration in case new services appeared during poll */
	new_ind = qmi_register_indications(&g_qmi);
	if (new_ind > 0)
		clog("registered QMI indications: +0x%x (mask=0x%x)", new_ind, g_qmi.ind_reg_mask);

	if (just_connected)
		data_adopt_or_clean();
	if (settled)
		data_reconcile(&cur);

	commit_and_publish(&cur, just_connected);
	if (just_connected && fn_notify_post)
		fn_notify_post("kCTDaemonReadyLocalNotification");
}

/*
 * (sweetcelld) airplane mode: RadiosPreferences (AppSupport, as Control Center and Settings use it) on the QMI queue,
 * with a delegate whose airplaneModeChanged is called when another process changes it. On a change: the modem to low
 * power or back online, the data session follows (data_reconcile), and the CoreTelephony clients are told.
 */
@interface HotRadiosWatcher : NSObject
@end

static id g_radios;
static HotRadiosWatcher *g_radios_watcher;

static bool radios_airplane_mode(void)
{
	if (!g_radios)
		return g_airplane_mode;
	if ([g_radios respondsToSelector:@selector(refresh)])
		[g_radios performSelector:@selector(refresh)];
	return ((BOOL (*)(id, SEL))objc_msgSend)(g_radios, sel_registerName("airplaneMode"));
}

@implementation HotRadiosWatcher
- (void)airplaneModeChanged
{
	bool now = radios_airplane_mode();
	if (now == g_airplane_mode)
		return;
	g_airplane_mode = now;
	clog("AirplaneMode changed -> %d", now ? 1 : 0);
	trigger_qmi_radio_power(!now);
	broadcast_data_settings(false);
}
@end

static void radios_watch(void)
{
	(void)dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_NOW);
	Class rc = NSClassFromString(@"RadiosPreferences");
	if (!rc || ![rc instancesRespondToSelector:@selector(initWithQueue:)]) {
		clog("RadiosPreferences not found: airplane mode not followed");
		return;
	}
	g_radios = ((id (*)(id, SEL, dispatch_queue_t))objc_msgSend)([rc alloc], @selector(initWithQueue:), g_qmi_queue);
	g_radios_watcher = [HotRadiosWatcher new];
	((void (*)(id, SEL, id))objc_msgSend)(g_radios, sel_registerName("setDelegate:"), g_radios_watcher);
	dispatch_async(g_qmi_queue, ^{
		bool now = radios_airplane_mode();
		clog("airplane mode %d at start (RadiosPreferences)", now ? 1 : 0);
		if (now != g_airplane_mode)
			[g_radios_watcher airplaneModeChanged];
	});
}

static void trigger_qmi_radio_power(bool online)
{
	dispatch_async(g_qmi_queue, ^{
		g_online_attempts = 0;
		g_last_online_try_ms = 0;
		g_last_logged_dms_mode = 0xfe;
		if (g_qmi.fd >= 0 && qmi_has_service(&g_qmi, QMI_SVC_DMS)) {
			struct cellular_state cur = snapshot_state();
			if (online && !modem_settled()) {
				/* (sweetcelld) the poll brings it online once the modem has settled (WLFW hand-over) */
				clog("AirplaneMode off: radio goes online once the modem has settled");
				return;
			}
			if (!online && cur.data_connected)
				data_down(&cur, "airplane mode");
			uint16_t qerr = 0;
			int mrc = qmi_dms_set_operating_mode_ex(&g_qmi, online ? 0x00 : 0x01, &qerr);
			clog("AirplaneMode radio power -> %s: rc=%d qmi_err=0x%04x",
			     online ? "ONLINE" : "LOW_POWER", mrc, qerr);
			(void)qmi_poll_all(&g_qmi, &cur, !cur.modem_rev[0]);
			commit_and_publish(&cur, false);
		}
	});
}

/* ---- Entry Point ---- */

static HotXPCListenerSPI *g_ct_listener;
static HotCellularListenerDelegate *g_ct_delegate;

int main(int argc, char **argv)
{
	@autoreleasepool {
		bool foreground = false;
		for (int i = 1; i < argc; i++) {
			if (!strcmp(argv[i], "--enable-data"))
				g_enable_wds_data = true;
			else if (!strcmp(argv[i], "--no-status-publisher"))
				g_publish_system_status = false;
			else if (!strcmp(argv[i], "--foreground"))
				foreground = true;
			else if (!strcmp(argv[i], "--no-xpc"))
				g_no_xpc = true;
			else if (!strcmp(argv[i], "--apn") && i + 1 < argc)
				snprintf(g_configured_apn, sizeof(g_configured_apn), "%s", argv[++i]);
		}

		signal(SIGPIPE, SIG_IGN);
		(void)setpriority(PRIO_DARWIN_PROCESS, 0, 0);

		(void)mkdir(SWEETCELL_DIR, 0755);
		if (!foreground) {
			struct timeval bt = { 0 };
			size_t blen = sizeof(bt);
			char want[32] = "", stamp[32] = "";
			if (sysctlbyname("kern.boottime", &bt, &blen, NULL, 0) == 0)
				snprintf(want, sizeof(want), "%ld\n", (long)bt.tv_sec);
			FILE *sf = fopen(CELLULARD_STAMP, "r");
			if (sf) {
				if (!fgets(stamp, sizeof(stamp), sf))
					stamp[0] = '\0';
				fclose(sf);
			}
			/* Rotate to .prev only once per phone boot so intra-boot restarts keep history */
			if (!want[0] || strcmp(stamp, want) != 0) {
				(void)rename(CELLULARD_LOG, CELLULARD_LOG ".prev");
				if (want[0] && (sf = fopen(CELLULARD_STAMP, "w")) != NULL) {
					fputs(want, sf);
					fclose(sf);
				}
			}
			g_logf = fopen(CELLULARD_LOG, "a");
		}
		g_start_ms = cell_mono_ms();
		clog("sweetcelld starting (pid %d)%s", (int)getpid(), g_no_xpc ? ", --no-xpc: no listeners, no status publisher" : "");
		(void)dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_NOW);
		(void)[CTTelephonyNetworkInfo class];

		resolve_runtime_symbols();
		cellular_state_init(&g_state);
		g_qmi.fd = -1;
		g_xpc_clients = [NSMutableArray array];
		g_logged_unhandled = [NSMutableSet set];

		load_config();
		load_settings();
		g_debug_log = access(SWEETCELL_DIR "/debug", F_OK) == 0;
		clog("switches: Cellular Data %d, Data Roaming %d", g_cellular_data_enabled ? 1 : 0, g_data_roaming ? 1 : 0);
		g_qmi.rat_mode_pref = g_rat_mode_pref;
		if (g_no_xpc)
			g_publish_system_status = false;

		/* 1. Initialize SystemStatus publisher */
		init_system_status_publisher();
		publish_system_status(&g_state);

		/* 2. Start com.apple.commcenter.coretelephony.xpc NSXPCListener */
		Class listenerCls = g_no_xpc ? Nil : NSClassFromString(@"NSXPCListener");
		if (listenerCls) {
			g_ct_delegate = [[HotCellularListenerDelegate alloc] init];
			g_ct_listener = [(HotXPCListenerSPI *)[listenerCls alloc]
					 initWithMachServiceName:@"com.apple.commcenter.coretelephony.xpc"];
			g_ct_listener.delegate = g_ct_delegate;
			[g_ct_listener resume];
			clog("listening on com.apple.commcenter.coretelephony.xpc");
		} else if (!g_no_xpc) {
			clog("ERROR: NSXPCListener class not found");
		}

		/* 3. Start com.apple.commcenter.xpc legacy CTServerConnection listener */
		dispatch_queue_t legacy_q = dispatch_queue_create("com.ios26hot.cellulard.legacyxpc",
								  DISPATCH_QUEUE_SERIAL);
		if (!g_no_xpc)
			start_legacy_commcenter_xpc(legacy_q);

		/* 4. Start QMI/QRTR queue, CallKit CXXPCProvider, CLI control socket & poll loop */
		g_qmi_queue = dispatch_queue_create("com.ios26hot.cellulard.qmi", DISPATCH_QUEUE_SERIAL);
		dispatch_async(g_qmi_queue, ^{
			try_connect_and_sync();
		});

		g_poll_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_qmi_queue);
		dispatch_source_set_timer(g_poll_timer,
					  dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
					  5 * NSEC_PER_SEC,
					  500 * NSEC_PER_MSEC);
		dispatch_source_set_event_handler(g_poll_timer, ^{
			try_connect_and_sync();
		});
		dispatch_resume(g_poll_timer);

		/* indications (registration, signal, the data session's end) every second between polls */
		dispatch_source_t ind_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_qmi_queue);
		dispatch_source_set_timer(ind_timer, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), NSEC_PER_SEC,
					  200 * NSEC_PER_MSEC);
		dispatch_source_set_event_handler(ind_timer, ^{
			if (g_qmi.fd < 0)
				return;
			bool was = snapshot_state().data_connected;
			if (g_data_up)
				configd_follow_wifi();
			(void)qmi_drain_rx(&g_qmi, 0);
			if (was && !snapshot_state().data_connected) {
				struct cellular_state cur = snapshot_state();
				data_reconcile(&cur);
				commit_and_publish(&cur, false);
			}
		});
		dispatch_resume(ind_timer);

		/* (sweetcelld) airplane mode as Control Center sets it: AppSupport's RadiosPreferences and its delegate (iOS 26
		 * posts no "com.apple.radios.prefs" notification; the earlier watch never fired) */
		radios_watch();

		dispatch_main();
	}
	return 0;
}
