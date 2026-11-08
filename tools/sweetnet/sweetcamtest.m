/*
 * sweetcamtest [SECONDS] [OUT.png]: the camera through AVFoundation over SSH, for testing without hands on the phone.
 * Lists the video devices and the default one's formats, runs an AVCaptureSession (preset 1920x1080, video data output
 * in BGRA) for SECONDS (default 8), counts the frames that arrive and writes one (the last) as a PNG (default
 * /private/var/tmp/camtest.png). Needs tccd and the camera TCC entitlement (camtest.entitlements). iOS 18, arm64e +
 * pacstrip (tools/sweetnet/build.sh).
 */
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <stdio.h>
#include <stdlib.h>

@interface Sink : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (atomic) unsigned frames;
@property (atomic) unsigned dropped;
@property (atomic) CVPixelBufferRef last;
@end

@implementation Sink
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c
{
	CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
	if (self.frames == 0 && pb) {
		printf("first frame: %zux%zu %c%c%c%c\n", CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
		    (char)(CVPixelBufferGetPixelFormatType(pb) >> 24), (char)(CVPixelBufferGetPixelFormatType(pb) >> 16),
		    (char)(CVPixelBufferGetPixelFormatType(pb) >> 8), (char)CVPixelBufferGetPixelFormatType(pb));
		fflush(stdout);
	}
	self.frames++;
	if (pb && self.frames % 15 == 0) {
		CVPixelBufferRef old = self.last;
		self.last = CVPixelBufferRetain(pb);
		if (old) {
			CVPixelBufferRelease(old);
		}
	}
}
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c
{
	self.dropped++;
}
@end

static void
write_png(CVPixelBufferRef pb, const char *path)
{
	CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
	CIContext *ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @YES }];
	CGImageRef cg = [ctx createCGImage:img fromRect:img.extent];
	if (!cg) {
		printf("no picture made\n");
		return;
	}
	NSURL *u = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
	CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)u, CFSTR("public.png"), 1, NULL);
	CGImageDestinationAddImage(d, cg, NULL);
	printf("%s: %s\n", path, CGImageDestinationFinalize(d) ? "written" : "NOT written");
	CFRelease(d);
	CGImageRelease(cg);
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		double seconds = argc > 1 ? atof(argv[1]) : 8;
		const char *out = argc > 2 ? argv[2] : "/private/var/tmp/camtest.png";
		printf("authorization: %ld\n", (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]);
		AVCaptureDeviceDiscoverySession *ds = [AVCaptureDeviceDiscoverySession
		    discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
				  mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
		for (AVCaptureDevice *d in ds.devices) {
			printf("device: %s (%s), position %ld, %lu formats\n", d.localizedName.UTF8String, d.uniqueID.UTF8String, (long)d.position,
			    (unsigned long)d.formats.count);
		}
		AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
		if (!dev) {
			printf("no default video device\n");
			return 1;
		}
		unsigned i = 0;
		for (AVCaptureDeviceFormat *f in dev.formats) {
			CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
			AVFrameRateRange *r = f.videoSupportedFrameRateRanges.firstObject;
			if (i < 40) {
				printf("  format %u: %dx%d, %.0f-%.0f fps\n", i, dim.width, dim.height, r.minFrameRate, r.maxFrameRate);
			}
			i++;
		}
		NSError *err = nil;
		AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
		if (!in) {
			printf("no input: %s\n", err.description.UTF8String);
			return 1;
		}
		AVCaptureSession *s = [AVCaptureSession new];
		[s beginConfiguration];
		if ([s canSetSessionPreset:AVCaptureSessionPreset1920x1080]) {
			s.sessionPreset = AVCaptureSessionPreset1920x1080;
		}
		if (![s canAddInput:in]) {
			NSString *why = nil;
			SEL sel = NSSelectorFromString(@"_canAddInput:failureReason:");
			if ([s respondsToSelector:sel]) {
				BOOL (*f)(id, SEL, id, NSString **) = (BOOL (*)(id, SEL, id, NSString **))[s methodForSelector:sel];
				f(s, sel, in, &why);
			}
			printf("the session cannot take the input: %s\n", why ? why.UTF8String : "(no reason given)");
			printf("input ports: %s\n", in.ports.description.UTF8String);
			return 1;
		}
		[s addInput:in];
		AVCaptureVideoDataOutput *o = [AVCaptureVideoDataOutput new];
		o.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
		o.alwaysDiscardsLateVideoFrames = YES;
		Sink *sink = [Sink new];
		dispatch_queue_t q = dispatch_queue_create("frames", DISPATCH_QUEUE_SERIAL);
		[o setSampleBufferDelegate:sink queue:q];
		if (![s canAddOutput:o]) {
			printf("the session cannot take the output\n");
			return 1;
		}
		[s addOutput:o];
		[s commitConfiguration];
		printf("preset %s, active format %s\n", s.sessionPreset.UTF8String, dev.activeFormat.description.UTF8String);
		__block NSString *runtimeError = nil;
		[[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:s queue:nil
		    usingBlock:^(NSNotification *n) { runtimeError = [n.userInfo[AVCaptureSessionErrorKey] description]; }];
		[s startRunning];
		printf("running: %d\n", s.isRunning);
		fflush(stdout);
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
		[s stopRunning];
		printf("frames %u, dropped %u in %.1f s%s%s\n", sink.frames, sink.dropped, seconds, runtimeError ? ", runtime error: " : "",
		    runtimeError ? runtimeError.UTF8String : "");
		if (sink.last) {
			write_png(sink.last, out);
		}
		return sink.frames ? 0 : 2;
	}
}
