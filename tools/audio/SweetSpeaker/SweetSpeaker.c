/*
 * SweetSpeaker.driver: the Mi 8's loudspeaker as a Core Audio device on iOS 26, an AudioServerPlugIn that audiomxd
 * loads from /System/Library/Audio/Plug-Ins/HAL like Apple's own drivers there (BuiltinAudioPlugin, BTAudioHALPlugin...).
 *
 * One output device whose UID is "Speaker": VirtualAudio's DeviceFactory (HALDeviceManager.cpp) builds its device
 * classes by UID (Codec, Speaker, Receiver, Mic, AOP Audio-1, ...); the Null_Device it does not know got only null
 * ports, so routes went nowhere. One stream, 2 channels of Float32 at 48 kHz interleaved, one volume and one mute
 * control. What the HAL mixes for it is converted to 16-bit and appended to the kernel's speaker player
 * (kern.sweet_audio_play in bsd/dev/dipper_audio.c, xnu 3045/3046), which streams it to the audio DSP.
 *
 * Clock: the host clock at exactly 48 kHz (400 ticks of the 19.2 MHz timebase per frame); the DSP's bit clock comes from
 * the same crystal, so the two do not drift apart.
 *
 * The kernel player is started at StartIO; when that fails (the DSP comes up about 150 s into a boot, audiomxd starts IO
 * earlier) or the player stops on its own, a helper thread starts it again once a second while IO runs.
 *
 * The amp's on/off scripts come from TI's firmware and are registered by root (`dipper-speaker.sh amp-register`);
 * without them the stream runs and the amp stays off. ROM mode has no speaker protection, so the gain never exceeds
 * kGainCeiling whatever the volume control says.
 *
 * Logs to the unified log, subsystem com.sweet.SweetSpeaker (`sweetlog 60 SweetSpeaker`).
 */
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/errno.h>
#include <sys/sysctl.h>
#include <unistd.h>

enum {
	kObjectID_PlugIn = kAudioObjectPlugInObject,
	kObjectID_Device = 2,
	kObjectID_Stream = 3,
	kObjectID_Volume = 4,
	kObjectID_Mute = 5,
};

#define kDeviceUID              "Speaker"
#define kDeviceModelUID         "SweetSpeaker"
#define kSampleRate             48000.0
#define kChannels               2u
#define kZeroTimeStampPeriod    16384u          /* frames between two zero time stamps */
#define kSafetyOffset           480u            /* 10 ms */
#define kLatency                4800u           /* what plays after our timeline: 4 x 20 ms queued in the DSP + its own */
#define kPrefillFrames          4800u           /* zeros ahead of the first mix: room for the IO thread's jitter */
#define kVolumeMinDB            (-48.0f)
#define kVolumeMaxDB            0.0f
#define kGainCeiling            0.25f           /* -12 dB: no speaker protection in the amp's ROM mode */

/* kern.sweet_audio_play (dipper_audio.c) */
enum { PL_OP_START = 1, PL_OP_STOP = 2, PL_OP_DATA = 3, PL_OP_DRAIN = 4 };
struct pl_status {
	uint32_t state, result, ring, period;
	uint64_t written, sent, played;
	uint32_t queued, zeros, gaps, writes;
	uint32_t errors, handle, copp, amp_checks;
	uint8_t flags1, flags2, amp, reserved;
	uint64_t done_time;
} __attribute__((packed));
#define PL_DATA_MAX             65536u

static os_log_t gLog;
static AudioServerPlugInHostRef gHost;
static atomic_uint gRefCount = 1;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gIOCount;
static Boolean gStreamActive = true;
static Float32 gVolumeScalar = 0.5f;
static UInt32 gMute;
static Float64 gHostTicksPerFrame;
static UInt64 gAnchorHostTime;
static Float64 gNextSample;                     /* the sample time the kernel's ring continues with */
static atomic_bool gKernelOK;                   /* the kernel's player runs and takes our data */
static atomic_bool gResync;                     /* restart the timeline (prefill) at the next mix */
static Boolean gLinkRunning;
static unsigned gDropped, gErrors;
/* diagnostics, logged at StopIO: the HAL's cycles, our timeline fixes, the kernel ring's lowest fill and its gaps */
static struct {
	unsigned cycles, skips, skipped, overlaps, overlapped, min_buf, max_buf, gap_n;
	uint64_t min_fill;
	uint32_t last_gaps;
	unsigned gap_ms[12];
} gDiag;

static Float32
volume_db(Float32 scalar)
{
	return kVolumeMinDB + fmaxf(0.0f, fminf(1.0f, scalar)) * (kVolumeMaxDB - kVolumeMinDB);
}

static Float32
volume_scalar(Float32 db)
{
	return (fmaxf(kVolumeMinDB, fminf(kVolumeMaxDB, db)) - kVolumeMinDB) / (kVolumeMaxDB - kVolumeMinDB);
}

static float
output_gain(void)
{
	if (gMute || gVolumeScalar <= 0.0f) {
		return 0.0f;
	}
	return fminf(kGainCeiling, powf(10.0f, volume_db(gVolumeScalar) / 20.0f));
}

/* data comes from the IO thread only (its own buffer); start/stop from the HAL's other threads */
static int
play_op(uint32_t op, const void *data, size_t len)
{
	static uint8_t io_buf[4 + PL_DATA_MAX];
	uint8_t ctl[4], *buf = len ? io_buf : ctl;
	memcpy(buf, &op, 4);
	if (len) {
		memcpy(buf + 4, data, len);
	}
	return sysctlbyname("kern.sweet_audio_play", NULL, NULL, buf, 4 + len) ? errno : 0;
}

/* frames of 16-bit stereo zeros, in pieces the sysctl takes */
static void
append_zeros(UInt32 frames)
{
	static const int16_t zeros[4096 * kChannels];
	while (frames && atomic_load(&gKernelOK)) {
		UInt32 n = frames < 4096u ? frames : 4096u;
		int e = play_op(PL_OP_DATA, zeros, n * kChannels * sizeof(int16_t));
		if (e == EPIPE || e == ENXIO) {
			atomic_store(&gKernelOK, false);       /* the player stopped: the helper thread restarts it */
		} else if (e) {
			gDropped += n;
		}
		frames -= n;
	}
}

#pragma mark - property helpers

static void
fill_format(AudioStreamBasicDescription *f)
{
	memset(f, 0, sizeof(*f));
	f->mSampleRate = kSampleRate;
	f->mFormatID = kAudioFormatLinearPCM;
	f->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
	f->mBytesPerPacket = kChannels * sizeof(Float32);
	f->mFramesPerPacket = 1;
	f->mBytesPerFrame = kChannels * sizeof(Float32);
	f->mChannelsPerFrame = kChannels;
	f->mBitsPerChannel = 32;
}

#define OUT(type, value)                                                                \
	do {                                                                            \
		if (inDataSize < sizeof(type)) {                                        \
			return kAudioHardwareBadPropertySizeError;                      \
		}                                                                       \
		*(type *)outData = (value);                                             \
		*outDataSize = sizeof(type);                                            \
		return kAudioHardwareNoError;                                           \
	} while (0)

static OSStatus
out_ids(const AudioObjectID *ids, UInt32 n, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
	UInt32 k = inDataSize / sizeof(AudioObjectID);
	if (k > n) {
		k = n;
	}
	memcpy(outData, ids, k * sizeof(AudioObjectID));
	*outDataSize = k * sizeof(AudioObjectID);
	return kAudioHardwareNoError;
}

static bool
is_output_or_global(AudioObjectPropertyScope s)
{
	return s == kAudioObjectPropertyScopeGlobal || s == kAudioObjectPropertyScopeOutput;
}

#pragma mark - IUnknown

static HRESULT SS_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG SS_AddRef(void *inDriver);
static ULONG SS_Release(void *inDriver);
static OSStatus SS_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus SS_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
    const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus SS_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus SS_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus SS_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus SS_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction, void *inChangeInfo);
static OSStatus SS_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction, void *inChangeInfo);
static Boolean SS_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress);
static OSStatus SS_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
    pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus SS_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
    pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
    const void *inQualifierData, UInt32 *outDataSize);
static OSStatus SS_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData,
    UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus SS_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData,
    UInt32 inDataSize, const void *inData);
static OSStatus SS_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SS_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SS_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus SS_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus SS_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus SS_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus SS_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
	NULL,
	SS_QueryInterface,
	SS_AddRef,
	SS_Release,
	SS_Initialize,
	SS_CreateDevice,
	SS_DestroyDevice,
	SS_AddDeviceClient,
	SS_RemoveDeviceClient,
	SS_PerformDeviceConfigurationChange,
	SS_AbortDeviceConfigurationChange,
	SS_HasProperty,
	SS_IsPropertySettable,
	SS_GetPropertyDataSize,
	SS_GetPropertyData,
	SS_SetPropertyData,
	SS_StartIO,
	SS_StopIO,
	SS_GetZeroTimeStamp,
	SS_WillDoIOOperation,
	SS_BeginIOOperation,
	SS_DoIOOperation,
	SS_EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

/* the factory named in Info.plist */
void *SweetSpeaker_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void *
SweetSpeaker_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
	(void)inAllocator;
	if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
		return NULL;
	}
	return gDriverRef;
}

static HRESULT
SS_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
	if (inDriver != gDriverRef || !outInterface) {
		return kAudioHardwareBadObjectError;
	}
	CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
	HRESULT r = E_NOINTERFACE;
	if (uuid && (CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID))) {
		atomic_fetch_add(&gRefCount, 1);
		*outInterface = gDriverRef;
		r = S_OK;
	}
	if (uuid) {
		CFRelease(uuid);
	}
	return r;
}

static ULONG
SS_AddRef(void *inDriver)
{
	return inDriver == gDriverRef ? atomic_fetch_add(&gRefCount, 1) + 1 : 0;
}

static ULONG
SS_Release(void *inDriver)
{
	return inDriver == gDriverRef ? atomic_fetch_sub(&gRefCount, 1) - 1 : 0;
}

#pragma mark - basic operations

static OSStatus
SS_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
	if (inDriver != gDriverRef) {
		return kAudioHardwareBadObjectError;
	}
	gHost = inHost;
	gLog = os_log_create("com.sweet.SweetSpeaker", "driver");
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	gHostTicksPerFrame = (1e9 * tb.denom / tb.numer) / kSampleRate;
	os_log(gLog, "SweetSpeaker: initialized, device UID %{public}s, %.1f host ticks per frame", kDeviceUID,
	    gHostTicksPerFrame);
	return kAudioHardwareNoError;
}

static OSStatus
SS_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
    const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID)
{
	(void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
	return kAudioHardwareUnsupportedOperationError;
}

static OSStatus
SS_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
	(void)inDriver; (void)inDeviceObjectID;
	return kAudioHardwareUnsupportedOperationError;
}

static OSStatus
SS_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo)
{
	(void)inClientInfo;
	return inDriver == gDriverRef && inDeviceObjectID == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus
SS_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo)
{
	(void)inClientInfo;
	return inDriver == gDriverRef && inDeviceObjectID == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus
SS_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction, void *inChangeInfo)
{
	(void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
	return kAudioHardwareNoError;
}

static OSStatus
SS_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction, void *inChangeInfo)
{
	(void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
	return kAudioHardwareNoError;
}

#pragma mark - properties

static Boolean
SS_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress)
{
	(void)inClientProcessID;
	if (inDriver != gDriverRef || !inAddress) {
		return false;
	}
	switch (inObjectID) {
	case kObjectID_PlugIn:
		switch (inAddress->mSelector) {
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioPlugInPropertyBoxList:
		case kAudioPlugInPropertyTranslateUIDToBox:
		case kAudioPlugInPropertyDeviceList:
		case kAudioPlugInPropertyTranslateUIDToDevice:
		case kAudioPlugInPropertyResourceBundle:
			return true;
		}
		return false;
	case kObjectID_Device:
		switch (inAddress->mSelector) {
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyName:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioDevicePropertyDeviceUID:
		case kAudioDevicePropertyModelUID:
		case kAudioDevicePropertyTransportType:
		case kAudioDevicePropertyRelatedDevices:
		case kAudioDevicePropertyClockDomain:
		case kAudioDevicePropertyDeviceIsAlive:
		case kAudioDevicePropertyDeviceIsRunning:
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
		case kAudioDevicePropertyLatency:
		case kAudioDevicePropertyStreams:
		case kAudioObjectPropertyControlList:
		case kAudioDevicePropertySafetyOffset:
		case kAudioDevicePropertyNominalSampleRate:
		case kAudioDevicePropertyAvailableNominalSampleRates:
		case kAudioDevicePropertyIsHidden:
		case kAudioDevicePropertyZeroTimeStampPeriod:
		case kAudioDevicePropertyPreferredChannelsForStereo:
		case kAudioDevicePropertyPreferredChannelLayout:
			return true;
		}
		return false;
	case kObjectID_Stream:
		switch (inAddress->mSelector) {
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyName:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioStreamPropertyIsActive:
		case kAudioStreamPropertyDirection:
		case kAudioStreamPropertyTerminalType:
		case kAudioStreamPropertyStartingChannel:
		case kAudioStreamPropertyLatency:
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			return true;
		}
		return false;
	case kObjectID_Volume:
		switch (inAddress->mSelector) {
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioControlPropertyScope:
		case kAudioControlPropertyElement:
		case kAudioLevelControlPropertyScalarValue:
		case kAudioLevelControlPropertyDecibelValue:
		case kAudioLevelControlPropertyDecibelRange:
		case kAudioLevelControlPropertyConvertScalarToDecibels:
		case kAudioLevelControlPropertyConvertDecibelsToScalar:
			return true;
		}
		return false;
	case kObjectID_Mute:
		switch (inAddress->mSelector) {
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioControlPropertyScope:
		case kAudioControlPropertyElement:
		case kAudioBooleanControlPropertyValue:
			return true;
		}
		return false;
	}
	return false;
}

static OSStatus
SS_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable)
{
	if (!SS_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress) || !outIsSettable) {
		return kAudioHardwareUnknownPropertyError;
	}
	AudioObjectPropertySelector s = inAddress->mSelector;
	*outIsSettable = (inObjectID == kObjectID_Device && s == kAudioDevicePropertyNominalSampleRate) ||
	    (inObjectID == kObjectID_Stream && (s == kAudioStreamPropertyIsActive || s == kAudioStreamPropertyVirtualFormat ||
	    s == kAudioStreamPropertyPhysicalFormat)) ||
	    (inObjectID == kObjectID_Volume && (s == kAudioLevelControlPropertyScalarValue ||
	    s == kAudioLevelControlPropertyDecibelValue)) ||
	    (inObjectID == kObjectID_Mute && s == kAudioBooleanControlPropertyValue);
	return kAudioHardwareNoError;
}

/* sizes and data from one place: GetPropertyData with a NULL buffer of the largest size answers the size */
static OSStatus
SS_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData,
    UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
	if (!SS_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress) || !outDataSize || !outData) {
		return kAudioHardwareUnknownPropertyError;
	}
	AudioObjectPropertySelector s = inAddress->mSelector;
	AudioObjectPropertyScope scope = inAddress->mScope;
	switch (inObjectID) {
	case kObjectID_PlugIn:
		switch (s) {
		case kAudioObjectPropertyBaseClass:
			OUT(AudioClassID, kAudioObjectClassID);
		case kAudioObjectPropertyClass:
			OUT(AudioClassID, kAudioPlugInClassID);
		case kAudioObjectPropertyOwner:
			OUT(AudioObjectID, kAudioObjectUnknown);
		case kAudioObjectPropertyManufacturer:
			OUT(CFStringRef, CFSTR("Bergamota"));
		case kAudioObjectPropertyOwnedObjects:
		case kAudioPlugInPropertyDeviceList: {
			AudioObjectID d = kObjectID_Device;
			return out_ids(&d, 1, inDataSize, outDataSize, outData);
		}
		case kAudioPlugInPropertyBoxList:
			*outDataSize = 0;
			return kAudioHardwareNoError;
		case kAudioPlugInPropertyTranslateUIDToBox:
			OUT(AudioObjectID, kAudioObjectUnknown);
		case kAudioPlugInPropertyTranslateUIDToDevice: {
			if (inQualifierDataSize != sizeof(CFStringRef) || !inQualifierData) {
				return kAudioHardwareBadPropertySizeError;
			}
			CFStringRef uid = *(const CFStringRef *)inQualifierData;
			OUT(AudioObjectID, uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo ? kObjectID_Device :
			    kAudioObjectUnknown);
		}
		case kAudioPlugInPropertyResourceBundle:
			OUT(CFStringRef, CFSTR(""));
		}
		break;
	case kObjectID_Device:
		switch (s) {
		case kAudioObjectPropertyBaseClass:
			OUT(AudioClassID, kAudioObjectClassID);
		case kAudioObjectPropertyClass:
			OUT(AudioClassID, kAudioDeviceClassID);
		case kAudioObjectPropertyOwner:
			OUT(AudioObjectID, kObjectID_PlugIn);
		case kAudioObjectPropertyName:
			OUT(CFStringRef, CFSTR("Speaker"));
		case kAudioObjectPropertyManufacturer:
			OUT(CFStringRef, CFSTR("Bergamota"));
		case kAudioObjectPropertyOwnedObjects: {
			AudioObjectID all[3] = { kObjectID_Stream, kObjectID_Volume, kObjectID_Mute };
			if (scope == kAudioObjectPropertyScopeInput) {
				*outDataSize = 0;
				return kAudioHardwareNoError;
			}
			return out_ids(all, 3, inDataSize, outDataSize, outData);
		}
		case kAudioDevicePropertyDeviceUID:
			OUT(CFStringRef, CFSTR(kDeviceUID));
		case kAudioDevicePropertyModelUID:
			OUT(CFStringRef, CFSTR(kDeviceModelUID));
		case kAudioDevicePropertyTransportType:
			OUT(UInt32, kAudioDeviceTransportTypeBuiltIn);
		case kAudioDevicePropertyRelatedDevices: {
			AudioObjectID d = kObjectID_Device;
			return out_ids(&d, 1, inDataSize, outDataSize, outData);
		}
		case kAudioDevicePropertyClockDomain:
			OUT(UInt32, 0);
		case kAudioDevicePropertyDeviceIsAlive:
			OUT(UInt32, 1);
		case kAudioDevicePropertyDeviceIsRunning: {
			pthread_mutex_lock(&gStateMutex);
			UInt32 running = gIOCount > 0;
			pthread_mutex_unlock(&gStateMutex);
			OUT(UInt32, running);
		}
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
			OUT(UInt32, scope != kAudioObjectPropertyScopeInput);
		case kAudioDevicePropertyLatency:
			OUT(UInt32, scope == kAudioObjectPropertyScopeInput ? 0 : kLatency);
		case kAudioDevicePropertyStreams: {
			AudioObjectID st = kObjectID_Stream;
			if (!is_output_or_global(scope)) {
				*outDataSize = 0;
				return kAudioHardwareNoError;
			}
			return out_ids(&st, 1, inDataSize, outDataSize, outData);
		}
		case kAudioObjectPropertyControlList: {
			AudioObjectID c[2] = { kObjectID_Volume, kObjectID_Mute };
			return out_ids(c, 2, inDataSize, outDataSize, outData);
		}
		case kAudioDevicePropertySafetyOffset:
			OUT(UInt32, scope == kAudioObjectPropertyScopeInput ? 0 : kSafetyOffset);
		case kAudioDevicePropertyNominalSampleRate:
			OUT(Float64, kSampleRate);
		case kAudioDevicePropertyAvailableNominalSampleRates: {
			AudioValueRange r = { kSampleRate, kSampleRate };
			OUT(AudioValueRange, r);
		}
		case kAudioDevicePropertyIsHidden:
			OUT(UInt32, 0);
		case kAudioDevicePropertyZeroTimeStampPeriod:
			OUT(UInt32, kZeroTimeStampPeriod);
		case kAudioDevicePropertyPreferredChannelsForStereo: {
			if (inDataSize < 2 * sizeof(UInt32)) {
				return kAudioHardwareBadPropertySizeError;
			}
			((UInt32 *)outData)[0] = 1;
			((UInt32 *)outData)[1] = 2;
			*outDataSize = 2 * sizeof(UInt32);
			return kAudioHardwareNoError;
		}
		case kAudioDevicePropertyPreferredChannelLayout: {
			UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
			if (inDataSize < size) {
				return kAudioHardwareBadPropertySizeError;
			}
			AudioChannelLayout *l = outData;
			memset(l, 0, size);
			l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
			l->mNumberChannelDescriptions = kChannels;
			l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
			l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
			*outDataSize = size;
			return kAudioHardwareNoError;
		}
		}
		break;
	case kObjectID_Stream:
		switch (s) {
		case kAudioObjectPropertyBaseClass:
			OUT(AudioClassID, kAudioObjectClassID);
		case kAudioObjectPropertyClass:
			OUT(AudioClassID, kAudioStreamClassID);
		case kAudioObjectPropertyOwner:
			OUT(AudioObjectID, kObjectID_Device);
		case kAudioObjectPropertyName:
			OUT(CFStringRef, CFSTR("Speaker"));
		case kAudioObjectPropertyOwnedObjects:
			*outDataSize = 0;
			return kAudioHardwareNoError;
		case kAudioStreamPropertyIsActive:
			OUT(UInt32, gStreamActive);
		case kAudioStreamPropertyDirection:
			OUT(UInt32, 0);         /* output */
		case kAudioStreamPropertyTerminalType:
			OUT(UInt32, kAudioStreamTerminalTypeSpeaker);
		case kAudioStreamPropertyStartingChannel:
			OUT(UInt32, 1);
		case kAudioStreamPropertyLatency:
			OUT(UInt32, 0);
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat: {
			AudioStreamBasicDescription f;
			fill_format(&f);
			OUT(AudioStreamBasicDescription, f);
		}
		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats: {
			AudioStreamRangedDescription r;
			fill_format(&r.mFormat);
			r.mSampleRateRange.mMinimum = r.mSampleRateRange.mMaximum = kSampleRate;
			OUT(AudioStreamRangedDescription, r);
		}
		}
		break;
	case kObjectID_Volume:
	case kObjectID_Mute:
		switch (s) {
		case kAudioObjectPropertyBaseClass:
			OUT(AudioClassID, inObjectID == kObjectID_Volume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
		case kAudioObjectPropertyClass:
			OUT(AudioClassID, inObjectID == kObjectID_Volume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
		case kAudioObjectPropertyOwner:
			OUT(AudioObjectID, kObjectID_Device);
		case kAudioObjectPropertyOwnedObjects:
			*outDataSize = 0;
			return kAudioHardwareNoError;
		case kAudioControlPropertyScope:
			OUT(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
		case kAudioControlPropertyElement:
			OUT(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
		case kAudioLevelControlPropertyScalarValue:
			OUT(Float32, gVolumeScalar);
		case kAudioLevelControlPropertyDecibelValue:
			OUT(Float32, volume_db(gVolumeScalar));
		case kAudioLevelControlPropertyDecibelRange: {
			AudioValueRange r = { kVolumeMinDB, kVolumeMaxDB };
			OUT(AudioValueRange, r);
		}
		case kAudioLevelControlPropertyConvertScalarToDecibels:
			if (inDataSize < sizeof(Float32)) {
				return kAudioHardwareBadPropertySizeError;
			}
			*(Float32 *)outData = volume_db(*(Float32 *)outData);
			*outDataSize = sizeof(Float32);
			return kAudioHardwareNoError;
		case kAudioLevelControlPropertyConvertDecibelsToScalar:
			if (inDataSize < sizeof(Float32)) {
				return kAudioHardwareBadPropertySizeError;
			}
			*(Float32 *)outData = volume_scalar(*(Float32 *)outData);
			*outDataSize = sizeof(Float32);
			return kAudioHardwareNoError;
		case kAudioBooleanControlPropertyValue:
			OUT(UInt32, gMute);
		}
		break;
	}
	return kAudioHardwareUnknownPropertyError;
}

static OSStatus
SS_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData,
    UInt32 *outDataSize)
{
	union {
		uint8_t bytes[256];
		Float32 f;
	} scratch = { { 0 } };
	if (!outDataSize) {
		return kAudioHardwareIllegalOperationError;
	}
	UInt32 size = 0;
	OSStatus r = SS_GetPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize,
	    inQualifierData, sizeof(scratch), &size, &scratch);
	*outDataSize = size;
	return r;
}

static OSStatus
SS_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData,
    UInt32 inDataSize, const void *inData)
{
	(void)inQualifierDataSize; (void)inQualifierData;
	Boolean settable = false;
	if (SS_IsPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, &settable) || !settable) {
		return kAudioHardwareUnknownPropertyError;
	}
	AudioObjectPropertySelector s = inAddress->mSelector;
	AudioObjectPropertyAddress changed = { s, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	switch (s) {
	case kAudioDevicePropertyNominalSampleRate:
		if (inDataSize != sizeof(Float64)) {
			return kAudioHardwareBadPropertySizeError;
		}
		return *(const Float64 *)inData == kSampleRate ? kAudioHardwareNoError : kAudioHardwareIllegalOperationError;
	case kAudioStreamPropertyIsActive:
		if (inDataSize != sizeof(UInt32)) {
			return kAudioHardwareBadPropertySizeError;
		}
		gStreamActive = *(const UInt32 *)inData != 0;
		break;
	case kAudioStreamPropertyVirtualFormat:
	case kAudioStreamPropertyPhysicalFormat: {
		AudioStreamBasicDescription f;
		fill_format(&f);
		if (inDataSize != sizeof(f)) {
			return kAudioHardwareBadPropertySizeError;
		}
		const AudioStreamBasicDescription *in = inData;
		return in->mSampleRate == f.mSampleRate && in->mFormatID == f.mFormatID && in->mChannelsPerFrame == f.mChannelsPerFrame &&
		    in->mBitsPerChannel == f.mBitsPerChannel ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
	}
	case kAudioLevelControlPropertyScalarValue:
	case kAudioLevelControlPropertyDecibelValue: {
		if (inDataSize != sizeof(Float32)) {
			return kAudioHardwareBadPropertySizeError;
		}
		Float32 v = *(const Float32 *)inData;
		gVolumeScalar = s == kAudioLevelControlPropertyScalarValue ? fmaxf(0.0f, fminf(1.0f, v)) : volume_scalar(v);
		os_log(gLog, "SweetSpeaker: volume %.3f (%.1f dB, gain %.4f)", gVolumeScalar, volume_db(gVolumeScalar),
		    output_gain());
		AudioObjectPropertyAddress both[2] = {
			{ kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
			{ kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
		};
		gHost->PropertiesChanged(gHost, kObjectID_Volume, 2, both);
		return kAudioHardwareNoError;
	}
	case kAudioBooleanControlPropertyValue:
		if (inDataSize != sizeof(UInt32)) {
			return kAudioHardwareBadPropertySizeError;
		}
		gMute = *(const UInt32 *)inData != 0;
		os_log(gLog, "SweetSpeaker: mute %u", gMute);
		break;
	default:
		return kAudioHardwareUnknownPropertyError;
	}
	gHost->PropertiesChanged(gHost, inObjectID, 1, &changed);
	return kAudioHardwareNoError;
}

#pragma mark - IO

/* START (a STOP first if something else left it playing), gStateMutex held */
static int
kernel_start(void)
{
	int e = play_op(PL_OP_START, NULL, 0);
	if (e == EBUSY) {
		play_op(PL_OP_STOP, NULL, 0);
		e = play_op(PL_OP_START, NULL, 0);
	}
	if (e == 0) {
		atomic_store(&gResync, true);
		atomic_store(&gKernelOK, true);
	}
	return e;
}

static void *
link_thread(void *arg)
{
	(void)arg;
	unsigned tries = 0;
	for (;;) {
		sleep(1);
		pthread_mutex_lock(&gStateMutex);
		if (!gIOCount) {
			gLinkRunning = false;
			pthread_mutex_unlock(&gStateMutex);
			return NULL;
		}
		if (!atomic_load(&gKernelOK)) {
			int e = kernel_start();
			if (e == 0 || tries++ % 60 == 0) {
				os_log(gLog, "SweetSpeaker: kernel player %{public}s (%d, try %u)", e ? "still not up" : "on", e, tries);
			}
			if (e == 0) {
				tries = 0;
			}
		}
		pthread_mutex_unlock(&gStateMutex);
	}
}

static OSStatus
SS_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
	(void)inClientID;
	if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
		return kAudioHardwareBadObjectError;
	}
	pthread_mutex_lock(&gStateMutex);
	if (gIOCount++ == 0) {
		gAnchorHostTime = mach_absolute_time();
		gDropped = gErrors = 0;
		memset(&gDiag, 0, sizeof(gDiag));
		gDiag.min_fill = UINT64_MAX;
		gDiag.min_buf = UINT32_MAX;
		int e = kernel_start();                 /* here, so the first sound is not lost; else the helper retries */
		os_log(gLog, "SweetSpeaker: start IO: kernel player %{public}s (%d), gain %.4f", e ? "not up yet" : "on", e,
		    output_gain());
		pthread_t th;
		if (!gLinkRunning && pthread_create(&th, NULL, link_thread, NULL) == 0) {
			pthread_detach(th);
			gLinkRunning = true;
		}
	}
	pthread_mutex_unlock(&gStateMutex);
	return kAudioHardwareNoError;
}

static OSStatus
SS_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
	(void)inClientID;
	if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
		return kAudioHardwareBadObjectError;
	}
	pthread_mutex_lock(&gStateMutex);
	if (gIOCount && --gIOCount == 0) {
		if (atomic_exchange(&gKernelOK, false)) {
			play_op(PL_OP_STOP, NULL, 0);
		}
		os_log(gLog, "SweetSpeaker: stop IO: %u frames dropped, %u write errors; %u cycles of %u-%u frames, %u skips (%u frames), "
		    "%u overlaps (%u frames); kernel ring lowest %llu bytes, %u gaps at ms %u %u %u %u %u %u %u %u %u %u %u %u", gDropped,
		    gErrors, gDiag.cycles, gDiag.min_buf, gDiag.max_buf, gDiag.skips, gDiag.skipped, gDiag.overlaps, gDiag.overlapped,
		    gDiag.min_fill, gDiag.last_gaps, gDiag.gap_ms[0], gDiag.gap_ms[1], gDiag.gap_ms[2], gDiag.gap_ms[3], gDiag.gap_ms[4],
		    gDiag.gap_ms[5], gDiag.gap_ms[6], gDiag.gap_ms[7], gDiag.gap_ms[8], gDiag.gap_ms[9], gDiag.gap_ms[10], gDiag.gap_ms[11]);
	}
	pthread_mutex_unlock(&gStateMutex);
	return kAudioHardwareNoError;
}

/* the host clock at the nominal rate, one time stamp per kZeroTimeStampPeriod frames since StartIO */
static OSStatus
SS_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
    Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed)
{
	(void)inDriver; (void)inDeviceObjectID; (void)inClientID;
	Float64 ticks = gHostTicksPerFrame * kZeroTimeStampPeriod;
	UInt64 n = (UInt64)((Float64)(mach_absolute_time() - gAnchorHostTime) / ticks);
	*outSampleTime = (Float64)(n * kZeroTimeStampPeriod);
	*outHostTime = gAnchorHostTime + (UInt64)((Float64)n * ticks);
	*outSeed = 1;
	return kAudioHardwareNoError;
}

static OSStatus
SS_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace)
{
	(void)inDriver; (void)inDeviceObjectID; (void)inClientID;
	*outWillDo = inOperationID == kAudioServerPlugInIOOperationWriteMix;
	*outWillDoInPlace = true;
	return kAudioHardwareNoError;
}

static OSStatus
SS_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
	(void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize;
	(void)inIOCycleInfo;
	return kAudioHardwareNoError;
}

/* WriteMix: Float32 stereo -> 16-bit with the volume, appended to the kernel's ring in sample-time order */
static OSStatus
SS_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
    UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
    void *ioMainBuffer, void *ioSecondaryBuffer)
{
	(void)inDriver; (void)inDeviceObjectID; (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
	if (inOperationID != kAudioServerPlugInIOOperationWriteMix || !atomic_load(&gKernelOK) || !ioMainBuffer) {
		return kAudioHardwareNoError;
	}
	if (atomic_exchange(&gResync, false)) {
		gNextSample = -1;
	}
	static int16_t pcm[PL_DATA_MAX / sizeof(int16_t)];
	const Float32 *in = ioMainBuffer;
	UInt32 frames = inIOBufferFrameSize;
	Float64 t = inIOCycleInfo->mOutputTime.mSampleTime;
	if (gNextSample < 0) {
		append_zeros(kPrefillFrames);
	} else if (t > gNextSample && t - gNextSample < kSampleRate) {
		gDiag.skips++;
		gDiag.skipped += (unsigned)(t - gNextSample);
		if (gDiag.skips <= 20) {
			os_log(gLog, "SweetSpeaker: the HAL skipped %.0f frames at sample %.0f (cycle %u, %u frames)", t - gNextSample, t,
			    gDiag.cycles, inIOBufferFrameSize);
		}
		append_zeros((UInt32)(t - gNextSample));        /* the HAL skipped ahead: keep the timeline */
	} else if (t < gNextSample) {
		UInt32 skip = (UInt32)fmin(gNextSample - t, (Float64)frames);  /* already appended */
		gDiag.overlaps++;
		gDiag.overlapped += skip;
		if (gDiag.overlaps <= 20) {
			os_log(gLog, "SweetSpeaker: the HAL went back %u frames at sample %.0f (cycle %u)", skip, t, gDiag.cycles);
		}
		in += skip * kChannels;
		frames -= skip;
		t += skip;
	}
	gNextSample = t + frames;
	if (gDiag.cycles < 3) {
		os_log(gLog, "SweetSpeaker: cycle %u: %u frames at %.0f, now %.0f, host ticks per frame main %.3f device %.3f, "
		    "nominal buffer %u", gDiag.cycles, inIOBufferFrameSize, inIOCycleInfo->mOutputTime.mSampleTime,
		    inIOCycleInfo->mCurrentTime.mSampleTime, inIOCycleInfo->mMainHostTicksPerFrame,
		    inIOCycleInfo->mDeviceHostTicksPerFrame, inIOCycleInfo->mNominalIOBufferFrameSize);
	}
	gDiag.cycles++;
	gDiag.min_buf = inIOBufferFrameSize < gDiag.min_buf ? inIOBufferFrameSize : gDiag.min_buf;
	gDiag.max_buf = inIOBufferFrameSize > gDiag.max_buf ? inIOBufferFrameSize : gDiag.max_buf;
	{
		/* the ring's fill before this cycle's data, and any new gap (zeros the kernel sent after the data started) */
		struct pl_status st;
		size_t len = sizeof(st);
		if (sysctlbyname("kern.sweet_audio_play", &st, &len, NULL, 0) == 0) {
			uint64_t fill = st.written - st.played;
			if (fill < gDiag.min_fill) {
				gDiag.min_fill = fill;
			}
			while (gDiag.last_gaps < st.gaps) {
				if (gDiag.gap_n < 12) {
					gDiag.gap_ms[gDiag.gap_n++] = (unsigned)((mach_absolute_time() - gAnchorHostTime) / gHostTicksPerFrame / 48.0);
				}
				if (gDiag.last_gaps < 20) {
					os_log(gLog, "SweetSpeaker: the kernel ring ran dry (gap %u) at cycle %u, %u frames, ring fill now %llu bytes",
					    gDiag.last_gaps + 1, gDiag.cycles, inIOBufferFrameSize, fill);
				}
				gDiag.last_gaps++;
			}
		}
	}
	float g = output_gain() * 32767.0f;
	while (frames) {
		UInt32 n = frames < PL_DATA_MAX / (kChannels * sizeof(int16_t)) ? frames : PL_DATA_MAX / (kChannels * sizeof(int16_t));
		for (UInt32 i = 0; i < n * kChannels; i++) {
			float v = in[i] * g;
			pcm[i] = (int16_t)(v > 32767.0f ? 32767.0f : v < -32768.0f ? -32768.0f : v);
		}
		int e = play_op(PL_OP_DATA, pcm, n * kChannels * sizeof(int16_t));
		if (e == EAGAIN) {
			gDropped += n;
		} else if (e == EPIPE || e == ENXIO) {
			atomic_store(&gKernelOK, false);       /* the player stopped: the helper thread restarts it */
			break;
		} else if (e) {
			gErrors++;
		}
		in += n * kChannels;
		frames -= n;
	}
	return kAudioHardwareNoError;
}

static OSStatus
SS_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
	(void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize;
	(void)inIOCycleInfo;
	return kAudioHardwareNoError;
}
