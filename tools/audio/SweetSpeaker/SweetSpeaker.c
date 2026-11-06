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
 * without them the stream runs and the amp stays off. ROM mode has no speaker protection, so everything goes through
 * the speaker's guard (guard.c: +12 dB make-up for Apple's n104_speaker_general chain, 200 Hz high-pass, power limits
 * over 0.2/3/60 s, peaks at most -3 dBFS) after the volume control.
 *
 * A second device, UID "Actuator" (1 channel), is the vibration motor: VirtualAudio's actuator device
 * (n104_actuator_general) renders iOS's haptics there when MobileGestalt says closed-loop haptics (ADT /product/haptics),
 * and each burst of waveform above kHapThreshold becomes one kern.sweet_haptic request (bsd/dev/dipper_haptics.c, xnu
 * 3049: duration, drive voltage from the peak) written by a helper thread. Not a waveform player: the PMI8998 drives
 * the LRA at its own frequency.
 *
 * A third device, UID "Mic" (1 input channel), is the handset's analog microphone: VirtualAudio's DeviceFactory makes
 * "Mic" (like "DigitalMic" and "Digital Mic") a Device_DigitalMic_Aspen, which creates the built-in microphone port. A
 * reader thread keeps the kernel's capture running (kern.sweet_audio_rec, dipper_audio.c, xnu 3065: its start brings the
 * codec up when needed) and copies what it captured into a local ring by kernel sample position; ReadInput takes the
 * HAL's input sample time kMicDelay frames behind the newest captured sample (the kernel's data comes in 20 ms pieces)
 * and moves that point again when the two timelines drift apart (counted as resyncs). Same host clock as the speaker.
 *
 * Logs to the unified log, subsystem com.sweet.SweetSpeaker (`sweetlog 60 SweetSpeaker`).
 */
#include <CoreAudio/AudioServerPlugIn.h>
#include "guard.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/semaphore.h>
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
	kObjectID_Actuator = 6,         /* the Taptic Engine's device: VirtualAudio's DeviceFactory knows "Actuator" */
	kObjectID_ActuatorStream = 7,
	kObjectID_Mic = 8,              /* the handset mic: VirtualAudio's DeviceFactory knows "Mic" (Device_DigitalMic_Aspen) */
	kObjectID_MicStream = 9,
	kObjectID_MicSource = 10,       /* the mic's data source control: the HAL's 'ssrc' / 'ssc#' come from it */
};

#define kDeviceUID              "Speaker"
#define kDeviceModelUID         "SweetSpeaker"
#define kActuatorUID            "Actuator"
#define kActuatorModelUID       "SweetActuator"
#define kMicUID                 "Mic"
#define kMicModelUID            "SweetMic"
#define kMicRing                65536u          /* samples of the local capture ring (1.4 s), a power of 2 */
#define kMicDelay               2880u           /* 60 ms: 2 of the kernel's 20 ms pieces + the reader's 5 ms polls + margin */
#define kMicSafetyOffset        480u
#define kSampleRate             48000.0
#define kChannels               2u
#define kZeroTimeStampPeriod    16384u          /* frames between two zero time stamps */
#define kSafetyOffset           480u            /* 10 ms */
#define kLatency                4800u           /* what plays after our timeline: 4 x 20 ms queued in the DSP + its own */
#define kPrefillFrames          4800u           /* zeros ahead of the first mix: room for the IO thread's jitter */
#define kVolumeMinDB            (-48.0f)
#define kVolumeMaxDB            0.0f
#define kMakeupDB               12.0f           /* guard.c: Apple's speaker chain leaves 10.7-14 dB of headroom unused */

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
static struct ss_guard gGuard;                 /* touched by the IO thread only, between StartIO and StopIO */
static UInt64 gStopHostTime;
static UInt32 gMute;
static Float64 gHostTicksPerFrame;
static UInt64 gAnchorHostTime;
static UInt32 gActIOCount;                      /* the actuator's IO (its waveform becomes kern.sweet_haptic requests) */
static UInt64 gActAnchorHostTime;
static struct {
	unsigned cycles, active, said, commands, refused;
	float peak;
} gAct;
/* motor requests from the IO thread to the worker that writes kern.sweet_haptic (SPMI writes do not belong on it) */
static _Atomic uint32_t gHapMs, gHapMv;
static semaphore_t gHapSem;
#define kHapThreshold           0.02f           /* actuator samples under this are silence */
#define kHapMinMs               15u             /* a tap shorter than this is not felt */
#define kHapMinMv               1200u
#define kHapMaxMv               3100u           /* the DT's vmax-mv; the kernel clamps to it too */
static void *haptic_thread(void *arg);
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
/* the microphone (kern.sweet_audio_rec): the reader thread fills gMicRing up to gMicWpos (kernel sample positions) */
static UInt32 gMicIOCount;
static UInt64 gMicAnchorHostTime;
static Boolean gMicThreadRunning;
static int16_t gMicRing[kMicRing];
static _Atomic uint64_t gMicWpos, gMicBase;     /* captured up to (exclusive) / since (this capture's first sample) */
static atomic_bool gMicLive;                    /* the kernel capture runs and the reader follows it */
static atomic_bool gMicResync;                  /* place the read point again at the next ReadInput */
static Float64 gMicOffset;                      /* kernel sample position = HAL input sample time + gMicOffset */
static struct {
	unsigned cycles, silent, resyncs, restarts, said;
	uint64_t lost;
	float peak;
	double sum2, n;
} gMicDiag;
static void *mic_thread(void *arg);
/*
 * The mic's input data sources: VirtualAudio's SubPortPolicy reads the device's kAudioDevicePropertyDataSource ('ssrc',
 * input scope, a list), writes the built-in mic's active sub-ports there ('imic' 'smic' 'fmic' 'lmic' on this N104
 * database) and waits for the change notification (HALPropertySynchronizer). The HAL makes 'ssrc' / 'ssc#' of a plug-in
 * device from its data source control (kAudioDataSourceControlClassID, input scope): kObjectID_MicSource, a selector
 * whose current items are that list. There is one physical mic: the list is kept and reported, nothing else.
 */
#define kMicMaxSources          8u
static const UInt32 kMicKnownSources[4] = { 'imic', 'smic', 'fmic', 'lmic' };
static UInt32 gMicSources[kMicMaxSources] = { 'imic', 'smic', 'fmic', 'lmic' };
static UInt32 gMicNSources = 4;

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
	return powf(10.0f, volume_db(gVolumeScalar) / 20.0f);        /* the guard limits what reaches the speaker */
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

static bool
is_actuator(AudioObjectID o)
{
	return o == kObjectID_Actuator || o == kObjectID_ActuatorStream;
}

static bool
is_mic(AudioObjectID o)
{
	return o == kObjectID_Mic || o == kObjectID_MicStream;
}

static bool
is_device(AudioObjectID o)
{
	return o == kObjectID_Device || o == kObjectID_Actuator || o == kObjectID_Mic;
}

static UInt32
channels_of(AudioObjectID o)
{
	return is_actuator(o) || is_mic(o) ? 1u : kChannels;
}

static void
fill_format(AudioStreamBasicDescription *f, UInt32 channels)
{
	memset(f, 0, sizeof(*f));
	f->mSampleRate = kSampleRate;
	f->mFormatID = kAudioFormatLinearPCM;
	f->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
	f->mBytesPerPacket = channels * sizeof(Float32);
	f->mFramesPerPacket = 1;
	f->mBytesPerFrame = channels * sizeof(Float32);
	f->mChannelsPerFrame = channels;
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
	guard_init(&gGuard, (float)kSampleRate, kMakeupDB);
	pthread_t hth;
	if (semaphore_create(mach_task_self(), &gHapSem, SYNC_POLICY_FIFO, 0) == KERN_SUCCESS &&
	    pthread_create(&hth, NULL, haptic_thread, NULL) == 0) {
		pthread_detach(hth);
	}
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	gHostTicksPerFrame = (1e9 * tb.denom / tb.numer) / kSampleRate;
	os_log(gLog, "SweetSpeaker: initialized, devices %{public}s, %{public}s, %{public}s, %.1f host ticks per frame", kDeviceUID,
	    kActuatorUID, kMicUID, gHostTicksPerFrame);
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
	return inDriver == gDriverRef && is_device(inDeviceObjectID) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus
SS_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo)
{
	(void)inClientInfo;
	return inDriver == gDriverRef && is_device(inDeviceObjectID) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
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
	case kObjectID_Actuator:
	case kObjectID_Mic:
		switch (inAddress->mSelector) {
		case kAudioDevicePropertyPreferredChannelsForStereo:
			return inObjectID == kObjectID_Device;
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
		case kAudioDevicePropertyPreferredChannelLayout:
			return true;
		}
		return false;
	case kObjectID_MicSource:
		switch (inAddress->mSelector) {
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioControlPropertyScope:
		case kAudioControlPropertyElement:
		case kAudioSelectorControlPropertyCurrentItem:
		case kAudioSelectorControlPropertyAvailableItems:
		case kAudioSelectorControlPropertyItemName:
			return true;
		}
		return false;
	case kObjectID_Stream:
	case kObjectID_ActuatorStream:
	case kObjectID_MicStream:
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
	bool device = is_device(inObjectID);
	bool stream = inObjectID == kObjectID_Stream || inObjectID == kObjectID_ActuatorStream || inObjectID == kObjectID_MicStream;
	*outIsSettable = (device && s == kAudioDevicePropertyNominalSampleRate) ||
	    (inObjectID == kObjectID_MicSource && s == kAudioSelectorControlPropertyCurrentItem) ||
	    (stream && (s == kAudioStreamPropertyIsActive || s == kAudioStreamPropertyVirtualFormat ||
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
			AudioObjectID d[3] = { kObjectID_Device, kObjectID_Actuator, kObjectID_Mic };
			return out_ids(d, 3, inDataSize, outDataSize, outData);
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
			OUT(AudioObjectID, !uid ? kAudioObjectUnknown :
			    CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo ? kObjectID_Device :
			    CFStringCompare(uid, CFSTR(kActuatorUID), 0) == kCFCompareEqualTo ? kObjectID_Actuator :
			    CFStringCompare(uid, CFSTR(kMicUID), 0) == kCFCompareEqualTo ? kObjectID_Mic : kAudioObjectUnknown);
		}
		case kAudioPlugInPropertyResourceBundle:
			OUT(CFStringRef, CFSTR(""));
		}
		break;
	case kObjectID_Device:
	case kObjectID_Actuator:
	case kObjectID_Mic: {
		bool mic = inObjectID == kObjectID_Mic;
		switch (s) {
		case kAudioObjectPropertyBaseClass:
			OUT(AudioClassID, kAudioObjectClassID);
		case kAudioObjectPropertyClass:
			OUT(AudioClassID, kAudioDeviceClassID);
		case kAudioObjectPropertyOwner:
			OUT(AudioObjectID, kObjectID_PlugIn);
		case kAudioObjectPropertyName:
			OUT(CFStringRef, mic ? CFSTR("Mic") : inObjectID == kObjectID_Actuator ? CFSTR("Actuator") : CFSTR("Speaker"));
		case kAudioObjectPropertyManufacturer:
			OUT(CFStringRef, CFSTR("Bergamota"));
		case kAudioObjectPropertyOwnedObjects: {
			AudioObjectID all[3] = { kObjectID_Stream, kObjectID_Volume, kObjectID_Mute }, act = kObjectID_ActuatorStream;
			AudioObjectID mst[2] = { kObjectID_MicStream, kObjectID_MicSource };
			if (mic) {
				if (scope == kAudioObjectPropertyScopeOutput) {
					*outDataSize = 0;
					return kAudioHardwareNoError;
				}
				return out_ids(mst, 2, inDataSize, outDataSize, outData);
			}
			if (scope == kAudioObjectPropertyScopeInput) {
				*outDataSize = 0;
				return kAudioHardwareNoError;
			}
			return inObjectID == kObjectID_Actuator ? out_ids(&act, 1, inDataSize, outDataSize, outData) :
			    out_ids(all, 3, inDataSize, outDataSize, outData);
		}
		case kAudioDevicePropertyDeviceUID:
			OUT(CFStringRef, mic ? CFSTR(kMicUID) : inObjectID == kObjectID_Actuator ? CFSTR(kActuatorUID) : CFSTR(kDeviceUID));
		case kAudioDevicePropertyModelUID:
			OUT(CFStringRef, mic ? CFSTR(kMicModelUID) : inObjectID == kObjectID_Actuator ? CFSTR(kActuatorModelUID) :
			    CFSTR(kDeviceModelUID));
		case kAudioDevicePropertyTransportType:
			OUT(UInt32, kAudioDeviceTransportTypeBuiltIn);
		case kAudioDevicePropertyRelatedDevices:
			return out_ids(&inObjectID, 1, inDataSize, outDataSize, outData);
		case kAudioDevicePropertyClockDomain:
			OUT(UInt32, 0);
		case kAudioDevicePropertyDeviceIsAlive:
			OUT(UInt32, 1);
		case kAudioDevicePropertyDeviceIsRunning: {
			pthread_mutex_lock(&gStateMutex);
			UInt32 running = (mic ? gMicIOCount : inObjectID == kObjectID_Actuator ? gActIOCount : gIOCount) > 0;
			pthread_mutex_unlock(&gStateMutex);
			OUT(UInt32, running);
		}
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
			OUT(UInt32, mic ? scope != kAudioObjectPropertyScopeOutput : scope != kAudioObjectPropertyScopeInput);
		case kAudioDevicePropertyLatency:
			if (mic) {
				OUT(UInt32, scope == kAudioObjectPropertyScopeOutput ? 0 : kMicDelay);
			}
			OUT(UInt32, scope == kAudioObjectPropertyScopeInput ? 0 : kLatency);
		case kAudioDevicePropertyStreams: {
			AudioObjectID st = mic ? kObjectID_MicStream : inObjectID == kObjectID_Actuator ? kObjectID_ActuatorStream :
			    kObjectID_Stream;
			if (mic ? scope == kAudioObjectPropertyScopeOutput : !is_output_or_global(scope)) {
				*outDataSize = 0;
				return kAudioHardwareNoError;
			}
			return out_ids(&st, 1, inDataSize, outDataSize, outData);
		}
		case kAudioObjectPropertyControlList: {
			AudioObjectID c[2] = { kObjectID_Volume, kObjectID_Mute }, ms = kObjectID_MicSource;
			if (mic) {
				return out_ids(&ms, 1, inDataSize, outDataSize, outData);
			}
			return out_ids(c, inObjectID == kObjectID_Device ? 2 : 0, inDataSize, outDataSize, outData);
		}
		case kAudioDevicePropertySafetyOffset:
			if (mic) {
				OUT(UInt32, scope == kAudioObjectPropertyScopeOutput ? 0 : kMicSafetyOffset);
			}
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
			UInt32 ch = channels_of(inObjectID);
			UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + ch * sizeof(AudioChannelDescription));
			if (inDataSize < size) {
				return kAudioHardwareBadPropertySizeError;
			}
			AudioChannelLayout *l = outData;
			memset(l, 0, size);
			l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
			l->mNumberChannelDescriptions = ch;
			if (ch == 1) {
				l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
			} else {
				l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
				l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
			}
			*outDataSize = size;
			return kAudioHardwareNoError;
		}
		}
		break;
	}
	case kObjectID_Stream:
	case kObjectID_ActuatorStream:
	case kObjectID_MicStream:
		switch (s) {
		case kAudioObjectPropertyBaseClass:
			OUT(AudioClassID, kAudioObjectClassID);
		case kAudioObjectPropertyClass:
			OUT(AudioClassID, kAudioStreamClassID);
		case kAudioObjectPropertyOwner:
			OUT(AudioObjectID, inObjectID == kObjectID_MicStream ? kObjectID_Mic :
			    inObjectID == kObjectID_ActuatorStream ? kObjectID_Actuator : kObjectID_Device);
		case kAudioObjectPropertyName:
			OUT(CFStringRef, inObjectID == kObjectID_MicStream ? CFSTR("Mic") :
			    inObjectID == kObjectID_ActuatorStream ? CFSTR("Actuator") : CFSTR("Speaker"));
		case kAudioObjectPropertyOwnedObjects:
			*outDataSize = 0;
			return kAudioHardwareNoError;
		case kAudioStreamPropertyIsActive:
			OUT(UInt32, gStreamActive);
		case kAudioStreamPropertyDirection:
			OUT(UInt32, inObjectID == kObjectID_MicStream ? 1 : 0);  /* 1 input, 0 output */
		case kAudioStreamPropertyTerminalType:
			OUT(UInt32, inObjectID == kObjectID_MicStream ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
		case kAudioStreamPropertyStartingChannel:
			OUT(UInt32, 1);
		case kAudioStreamPropertyLatency:
			OUT(UInt32, 0);
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat: {
			AudioStreamBasicDescription f;
			fill_format(&f, channels_of(inObjectID));
			OUT(AudioStreamBasicDescription, f);
		}
		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats: {
			AudioStreamRangedDescription r;
			fill_format(&r.mFormat, channels_of(inObjectID));
			r.mSampleRateRange.mMinimum = r.mSampleRateRange.mMaximum = kSampleRate;
			OUT(AudioStreamRangedDescription, r);
		}
		}
		break;
	case kObjectID_MicSource:
		switch (s) {
		case kAudioObjectPropertyBaseClass:
			OUT(AudioClassID, kAudioSelectorControlClassID);
		case kAudioObjectPropertyClass:
			OUT(AudioClassID, kAudioDataSourceControlClassID);
		case kAudioObjectPropertyOwner:
			OUT(AudioObjectID, kObjectID_Mic);
		case kAudioObjectPropertyOwnedObjects:
			*outDataSize = 0;
			return kAudioHardwareNoError;
		case kAudioControlPropertyScope:
			OUT(AudioObjectPropertyScope, kAudioObjectPropertyScopeInput);
		case kAudioControlPropertyElement:
			OUT(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
		case kAudioSelectorControlPropertyCurrentItem: {
			/* as many as fit: the HAL reads one UInt32 when it activates the device, VirtualAudio the whole list */
			pthread_mutex_lock(&gStateMutex);
			OSStatus r = out_ids(gMicSources, gMicNSources, inDataSize, outDataSize, outData);
			pthread_mutex_unlock(&gStateMutex);
			return r;
		}
		case kAudioSelectorControlPropertyAvailableItems:
			return out_ids(kMicKnownSources, 4, inDataSize, outDataSize, outData);
		case kAudioSelectorControlPropertyItemName: {
			UInt32 id = inQualifierDataSize == sizeof(UInt32) && inQualifierData ? *(const UInt32 *)inQualifierData : 0;
			if (inDataSize < sizeof(CFStringRef)) {
				return kAudioHardwareBadPropertySizeError;
			}
			*(CFStringRef *)outData = CFStringCreateWithFormat(NULL, NULL, CFSTR("%c%c%c%c"), (char)(id >> 24),
			    (char)(id >> 16), (char)(id >> 8), (char)id);
			*outDataSize = sizeof(CFStringRef);
			return kAudioHardwareNoError;
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
	if (r == kAudioHardwareNoError && inObjectID == kObjectID_MicSource && inAddress &&
	    inAddress->mSelector == kAudioSelectorControlPropertyItemName) {
		CFStringRef made;
		memcpy(&made, scratch.bytes, sizeof(made));
		if (made) {
			CFRelease(made);                        /* the size query made a name nobody takes */
		}
	}
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
	case kAudioSelectorControlPropertyCurrentItem: {
		if (!inDataSize || inDataSize % sizeof(UInt32) || inDataSize > kMicMaxSources * sizeof(UInt32)) {
			return kAudioHardwareBadPropertySizeError;
		}
		pthread_mutex_lock(&gStateMutex);
		gMicNSources = inDataSize / sizeof(UInt32);
		memcpy(gMicSources, inData, inDataSize);
		pthread_mutex_unlock(&gStateMutex);
		char list[kMicMaxSources * 5 + 1] = "";
		for (UInt32 i = 0; i < inDataSize / sizeof(UInt32); i++) {
			UInt32 v = ((const UInt32 *)inData)[i];
			char one[6] = { (char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v, ' ', 0 };
			strlcat(list, one, sizeof(list));
		}
		os_log(gLog, "SweetSpeaker: mic: input data sources set to %{public}s(%u)", list, inDataSize / (UInt32)sizeof(UInt32));
		gHost->PropertiesChanged(gHost, kObjectID_MicSource, 1, &changed);
		return kAudioHardwareNoError;
	}
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
		fill_format(&f, channels_of(inObjectID));
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

/* the actuator: IO start/stop and its counters; actuator_mix turns what iOS plays on it into motor requests */
static OSStatus
actuator_io(bool start)
{
	pthread_mutex_lock(&gStateMutex);
	if (start && gActIOCount++ == 0) {
		gActAnchorHostTime = mach_absolute_time();
		memset(&gAct, 0, sizeof(gAct));
		os_log(gLog, "SweetSpeaker: actuator start IO");
	} else if (!start && gActIOCount && --gActIOCount == 0) {
		os_log(gLog, "SweetSpeaker: actuator stop IO: %u cycles, %u with a signal, peak %.4f, %u motor requests (%u refused)",
		    gAct.cycles, gAct.active, gAct.peak, gAct.commands, gAct.refused);
	}
	pthread_mutex_unlock(&gStateMutex);
	return kAudioHardwareNoError;
}

/* the worker: one kern.sweet_haptic write per request (ms, mV) */
static void *
haptic_thread(void *arg)
{
	(void)arg;
	for (;;) {
		semaphore_wait(gHapSem);
		struct { uint32_t ms, mv; } req = { atomic_exchange(&gHapMs, 0), atomic_load(&gHapMv) };
		if (req.ms && sysctlbyname("kern.sweet_haptic", NULL, NULL, &req, sizeof(req)) != 0) {
			gAct.refused++;
		}
	}
	return NULL;
}

/*
 * What iOS renders for the Taptic Engine, turned into what the Mi 8's motor can do (run at a strength, or not): per IO
 * cycle the span where the waveform is above kHapThreshold and its peak become one request of that many ms (at least
 * kHapMinMs) at a drive voltage that grows with the peak. A request while the motor runs moves its end on.
 */
static void
actuator_mix(const Float32 *in, UInt32 frames, Float64 sample_time)
{
	float peak = 0.0f, sum = 0.0f;
	UInt32 first = frames, last = 0;
	for (UInt32 i = 0; i < frames; i++) {
		float a = fabsf(in[i]);
		peak = fmaxf(peak, a);
		sum += in[i] * in[i];
		if (a > kHapThreshold) {
			first = i < first ? i : first;
			last = i;
		}
	}
	gAct.cycles++;
	gAct.peak = fmaxf(gAct.peak, peak);
	if (peak <= kHapThreshold) {
		return;
	}
	gAct.active++;
	uint32_t ms = (uint32_t)((last - first + 1) * 1000.0 / kSampleRate);
	ms = ms < kHapMinMs ? kHapMinMs : ms;
	uint32_t mv = kHapMinMv + (uint32_t)(fminf(peak, 1.0f) * (float)(kHapMaxMv - kHapMinMv));
	atomic_store(&gHapMv, mv);
	atomic_store(&gHapMs, ms);
	semaphore_signal(gHapSem);
	gAct.commands++;
	if (gAct.said++ < 24) {
		os_log(gLog, "SweetSpeaker: actuator: %u frames at %.0f, peak %.4f, rms %.4f -> motor %u ms at %u mV", frames,
		    sample_time, peak, sqrtf(sum / (float)frames), ms, mv);
	}
}

/* the microphone: kern.sweet_audio_rec ops, from the reader thread only (its buffer is static) */
enum { REC_OP_START = 1, REC_OP_STOP = 2, REC_OP_READ = 3 };
struct rec_hdr {
	uint64_t wpos, from;
	uint32_t n, state;
};
#define REC_READ_MAX            9600u           /* what the kernel returns per call: 200 ms */

static int
rec_op(uint32_t op, uint64_t pos, struct rec_hdr *h, int16_t **samples)
{
	static uint8_t buf[sizeof(struct rec_hdr) + REC_READ_MAX * sizeof(int16_t)];
	struct {
		uint32_t op, max;
		uint64_t pos;
	} q = { op, op == REC_OP_READ ? REC_READ_MAX : 0, pos };
	size_t len = sizeof(buf);
	if (sysctlbyname("kern.sweet_audio_rec", buf, &len, &q, sizeof(q)) != 0) {
		return errno;
	}
	if (len < sizeof(*h)) {
		return EIO;
	}
	memcpy(h, buf, sizeof(*h));
	if (len < sizeof(*h) + h->n * sizeof(int16_t)) {
		h->n = (uint32_t)((len - sizeof(*h)) / sizeof(int16_t));
	}
	if (samples) {
		*samples = (int16_t *)(void *)(buf + sizeof(*h));
	}
	return 0;
}

/*
 * While the mic's IO runs: start the kernel capture (again when it stopped), read what it captured every 5 ms into
 * gMicRing and publish the position; stop the capture when IO stops.
 */
static void *
mic_thread(void *arg)
{
	(void)arg;
	unsigned tries = 0;
	bool live = false;
	uint64_t rpos = 0, w0 = 0, w1 = 0, h0 = 0, h1 = 0, hstart = 0;
	for (;;) {
		pthread_mutex_lock(&gStateMutex);
		bool run = gMicIOCount > 0;
		if (!run) {
			gMicThreadRunning = false;
		}
		pthread_mutex_unlock(&gStateMutex);
		if (!run) {
			break;
		}
		struct rec_hdr h;
		int16_t *smp = NULL;
		if (!live) {
			int e = rec_op(REC_OP_START, 0, &h, NULL);
			if (e) {
				if (tries++ % 30 == 0) {
					os_log(gLog, "SweetSpeaker: mic: the kernel capture is not up yet (%d, try %u)", e, tries);
				}
				usleep(500000);
				continue;
			}
			rpos = h.wpos;
			h0 = 0;                                 /* the rate is measured from the first samples on */
			hstart = mach_absolute_time();
			atomic_store(&gMicBase, rpos);
			atomic_store_explicit(&gMicWpos, rpos, memory_order_release);
			atomic_store(&gMicResync, true);
			atomic_store(&gMicLive, true);
			live = true;
			os_log(gLog, "SweetSpeaker: mic: kernel capture on (after %u tries) at kernel sample %llu", tries,
			    (unsigned long long)rpos);
			tries = 0;
		}
		int e = rec_op(REC_OP_READ, rpos, &h, &smp);
		if (e || h.state == 0) {
			atomic_store(&gMicLive, false);
			live = false;
			gMicDiag.restarts++;
			os_log(gLog, "SweetSpeaker: mic: the kernel capture stopped (%d, state %u): starting it again", e, e ? 0 : h.state);
			continue;
		}
		if (h.from > rpos) {
			gMicDiag.lost += h.from - rpos;         /* the reader fell more than the kernel's 2 s behind */
		}
		for (uint32_t i = 0; i < h.n; i++) {
			gMicRing[(h.from + i) & (kMicRing - 1)] = smp[i];
		}
		rpos = h.from + h.n;
		atomic_store_explicit(&gMicWpos, rpos, memory_order_release);
		if (h.n) {
			uint64_t now = mach_absolute_time();
			if (!h0) {
				h0 = now;
				w0 = rpos;
				os_log(gLog, "SweetSpeaker: mic: first samples %.0f ms after the capture start",
				    (double)(now - hstart) / gHostTicksPerFrame / 48.0);
			}
			w1 = rpos;
			h1 = now;
		}
		if (h.n < REC_READ_MAX) {
			usleep(5000);
		}
	}
	if (live) {
		struct rec_hdr h;
		rec_op(REC_OP_STOP, 0, &h, NULL);
	}
	atomic_store(&gMicLive, false);
	double frames = h1 > h0 ? (double)(h1 - h0) / gHostTicksPerFrame : 0;
	os_log(gLog, "SweetSpeaker: mic: reader stopped: %llu samples in %.2f s of host time (%+.0f ppm against 48 kHz), %llu lost, "
	    "%u restarts", (unsigned long long)(w1 - w0), frames / kSampleRate, frames > 0 ? ((double)(w1 - w0) / frames - 1) * 1e6 : 0,
	    (unsigned long long)gMicDiag.lost, gMicDiag.restarts);
	return NULL;
}

static OSStatus
mic_io(bool start)
{
	pthread_mutex_lock(&gStateMutex);
	if (start && gMicIOCount++ == 0) {
		gMicAnchorHostTime = mach_absolute_time();
		memset(&gMicDiag, 0, sizeof(gMicDiag));
		atomic_store(&gMicResync, true);
		pthread_t th;
		if (!gMicThreadRunning && pthread_create(&th, NULL, mic_thread, NULL) == 0) {
			pthread_detach(th);
			gMicThreadRunning = true;
		}
		os_log(gLog, "SweetSpeaker: mic start IO");
	} else if (!start && gMicIOCount && --gMicIOCount == 0) {
		os_log(gLog, "SweetSpeaker: mic stop IO: %u cycles, %u without the kernel capture (zeros), %u resyncs; peak %.1f dBFS, "
		    "rms %.1f dBFS", gMicDiag.cycles, gMicDiag.silent, gMicDiag.resyncs, 20.0 * log10(gMicDiag.peak + 1e-9),
		    10.0 * log10(gMicDiag.n > 0 ? gMicDiag.sum2 / gMicDiag.n + 1e-18 : 1e-18));
	}
	pthread_mutex_unlock(&gStateMutex);
	return kAudioHardwareNoError;
}

/* ReadInput: frames of the HAL's input time line t.. from the local ring (zeros until the kernel capture runs) */
static void
mic_read(Float32 *out, UInt32 frames, Float64 t)
{
	gMicDiag.cycles++;
	if (!atomic_load(&gMicLive)) {
		memset(out, 0, frames * sizeof(Float32));
		gMicDiag.silent++;
		atomic_store(&gMicResync, true);
		return;
	}
	int64_t w = (int64_t)atomic_load_explicit(&gMicWpos, memory_order_acquire), base = (int64_t)atomic_load(&gMicBase);
	int64_t k = (int64_t)llround(t + gMicOffset);
	bool resync = atomic_exchange(&gMicResync, false);
	/* not there yet, or so old that the reader (up to REC_READ_MAX samples per write) may be overwriting it */
	if (!resync && (k + (int64_t)frames > w || k < w - (int64_t)(kMicRing - 2u * REC_READ_MAX))) {
		gMicDiag.resyncs++;
		if (gMicDiag.resyncs <= 20) {
			os_log(gLog, "SweetSpeaker: mic: input %lld..%lld but the capture is at %lld (cycle %u): placed again", k,
			    k + (int64_t)frames, w, gMicDiag.cycles);
		}
		resync = true;
	}
	if (resync) {
		gMicOffset = (Float64)(w - (int64_t)kMicDelay - (int64_t)frames) - t;
		k = (int64_t)llround(t + gMicOffset);
	}
	float peak = gMicDiag.peak;
	double s2 = 0;
	for (UInt32 i = 0; i < frames; i++) {
		int64_t p = k + (int64_t)i;
		float v = p < base || p >= w ? 0.0f : (float)gMicRing[(uint64_t)p & (kMicRing - 1)] * (1.0f / 32768.0f);
		out[i] = v;
		peak = fmaxf(peak, fabsf(v));
		s2 += (double)v * v;
	}
	gMicDiag.peak = peak;
	gMicDiag.sum2 += s2;
	gMicDiag.n += frames;
	if (gMicDiag.said < 3) {
		gMicDiag.said++;
		os_log(gLog, "SweetSpeaker: mic cycle: %u frames at %.0f -> kernel %lld (captured up to %lld), rms %.1f dBFS", frames, t,
		    k, w, 10.0 * log10(s2 / frames + 1e-18));
	}
}

static OSStatus
SS_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
	(void)inClientID;
	if (inDriver == gDriverRef && inDeviceObjectID == kObjectID_Actuator) {
		return actuator_io(true);
	}
	if (inDriver == gDriverRef && inDeviceObjectID == kObjectID_Mic) {
		return mic_io(true);
	}
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
		if (gStopHostTime) {                    /* the speaker cooled while nothing played */
			guard_rest(&gGuard, (float)((Float64)(gAnchorHostTime - gStopHostTime) / gHostTicksPerFrame / kSampleRate));
		}
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
	if (inDriver == gDriverRef && inDeviceObjectID == kObjectID_Actuator) {
		return actuator_io(false);
	}
	if (inDriver == gDriverRef && inDeviceObjectID == kObjectID_Mic) {
		return mic_io(false);
	}
	if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
		return kAudioHardwareBadObjectError;
	}
	pthread_mutex_lock(&gStateMutex);
	if (gIOCount && --gIOCount == 0) {
		if (atomic_exchange(&gKernelOK, false)) {
			play_op(PL_OP_STOP, NULL, 0);
		}
		gStopHostTime = mach_absolute_time();
		os_log(gLog, "SweetSpeaker: stop IO: the guard took at most %.1f dB off", -guard_take_min_db(&gGuard));
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
	(void)inDriver; (void)inClientID;
	UInt64 anchor = inDeviceObjectID == kObjectID_Mic ? gMicAnchorHostTime :
	    inDeviceObjectID == kObjectID_Actuator ? gActAnchorHostTime : gAnchorHostTime;
	Float64 ticks = gHostTicksPerFrame * kZeroTimeStampPeriod;
	UInt64 n = (UInt64)((Float64)(mach_absolute_time() - anchor) / ticks);
	*outSampleTime = (Float64)(n * kZeroTimeStampPeriod);
	*outHostTime = anchor + (UInt64)((Float64)n * ticks);
	*outSeed = 1;
	return kAudioHardwareNoError;
}

static OSStatus
SS_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace)
{
	(void)inDriver; (void)inClientID;
	*outWillDo = inOperationID == (inDeviceObjectID == kObjectID_Mic ? kAudioServerPlugInIOOperationReadInput :
	    kAudioServerPlugInIOOperationWriteMix);
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
	if (inDeviceObjectID == kObjectID_Mic) {
		if (inOperationID == kAudioServerPlugInIOOperationReadInput && ioMainBuffer) {
			mic_read(ioMainBuffer, inIOBufferFrameSize, inIOCycleInfo->mInputTime.mSampleTime);
		}
		return kAudioHardwareNoError;
	}
	if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inDeviceObjectID == kObjectID_Actuator && ioMainBuffer) {
		actuator_mix(ioMainBuffer, inIOBufferFrameSize, inIOCycleInfo->mOutputTime.mSampleTime);
		return kAudioHardwareNoError;
	}
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
	static float work[PL_DATA_MAX / sizeof(int16_t)];
	float g = output_gain();
	while (frames) {
		UInt32 n = frames < PL_DATA_MAX / (kChannels * sizeof(int16_t)) ? frames : PL_DATA_MAX / (kChannels * sizeof(int16_t));
		for (UInt32 i = 0; i < n * kChannels; i++) {
			work[i] = in[i] * g;
		}
		guard_run(&gGuard, work, n);
		for (UInt32 i = 0; i < n * kChannels; i++) {
			float v = work[i] * 32767.0f;
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
