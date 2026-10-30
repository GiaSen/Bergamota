/*
 * sweetuicache: register (or unregister) an app bundle with LaunchServices
 * so SpringBoard shows it, like the jailbreak-era `uicache -p`. Run as root:
 *   sweetuicache /Applications/Foo.app        register as a system app
 *   sweetuicache -u /Applications/Foo.app     unregister
 * Uses the private LSApplicationWorkspace API (MobileCoreServices), resolved
 * at run time; the binary is signed with the LaunchServices entitlements.
 * The app's PlugIns/ and Extensions/ go in _LSBundlePlugins, with their data and
 * group containers, as MobileInstallation registers them: an app registered
 * without it has no extensions at all (no widgets: chronod "Ignoring restricted
 * or unknown extension", SpringBoard's "Waiting..." tiles).
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

/* Security SPI: read a binary's entitlements without running it */
extern OSStatus SecStaticCodeCreateWithPathAndAttributes(CFURLRef path, uint32_t flags, CFDictionaryRef attributes, void **code);
extern OSStatus SecCodeCopySigningInformation(void *code, uint32_t flags, CFDictionaryRef *information);
extern const CFStringRef kSecCodeInfoEntitlementsDict;
#define kSecCSRequirementInformation (1u << 2)

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dict;
- (BOOL)unregisterApplication:(NSURL *)url;
- (BOOL)registerApplication:(NSURL *)url;
@end

@interface MCMContainer : NSObject
+ (instancetype)containerWithIdentifier:(NSString *)identifier createIfNecessary:(BOOL)create existed:(BOOL *)existed error:(NSError **)error;
- (NSURL *)url;
@end

static NSDictionary *
entitlements_of(NSString *path)
{
	void *code = NULL;
	CFDictionaryRef info = NULL;
	NSDictionary *ents = nil;
	if (SecStaticCodeCreateWithPathAndAttributes((__bridge CFURLRef)[NSURL fileURLWithPath:path], 0, NULL, &code) || !code)
		return nil;
	if (!SecCodeCopySigningInformation(code, kSecCSRequirementInformation, &info) && info) {
		ents = ((__bridge NSDictionary *)info)[(__bridge NSString *)kSecCodeInfoEntitlementsDict];
		CFRelease(info);
	}
	CFRelease(code);
	return ents;
}

static NSString *
container_path(NSString *cls, NSString *ident)
{
	return [[[NSClassFromString(cls) containerWithIdentifier:ident createIfNecessary:YES existed:NULL error:NULL] url] path];
}

static NSDictionary *
group_containers(NSDictionary *ents)
{
	NSMutableDictionary *groups = [NSMutableDictionary dictionary];
	NSDictionary *kinds = @{@"com.apple.security.application-groups": @"MCMSharedDataContainer",
	                        @"com.apple.security.system-groups": @"MCMSystemDataContainer"};
	for (NSString *key in kinds) {
		id ids = ents[key];
		if (![ids isKindOfClass:[NSArray class]])
			continue;
		for (NSString *g in ids) {
			NSString *c = container_path(kinds[key], g);
			if (c)
				groups[g] = c;
		}
	}
	return groups;
}

/* MobileInstallation's dictionary for every extension bundled in the app */
static NSDictionary *
plugins_of(NSString *path, NSString *owner)
{
	NSFileManager *fm = NSFileManager.defaultManager;
	NSMutableDictionary *plugins = [NSMutableDictionary dictionary];
	for (NSString *sub in @[@"PlugIns", @"Extensions"]) {
		NSString *dir = [path stringByAppendingPathComponent:sub];
		for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
			if (![name hasSuffix:@".appex"])
				continue;
			NSString *pp = [dir stringByAppendingPathComponent:name];
			NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[pp stringByAppendingPathComponent:@"Info.plist"]];
			NSString *pid = info[@"CFBundleIdentifier"], *exe = info[@"CFBundleExecutable"];
			if (pid == nil || exe == nil)
				continue;
			NSDictionary *ents = entitlements_of([pp stringByAppendingPathComponent:exe]) ?: @{};
			NSMutableDictionary *d = [@{
				@"ApplicationType": @"PluginKitPlugin",
				@"CFBundleIdentifier": pid,
				@"CodeInfoIdentifier": pid,
				@"CompatibilityState": @0,
				@"Entitlements": ents,
				@"GroupContainers": group_containers(ents),
				@"Path": pp,
				@"PluginOwnerBundleID": owner,
				@"SignatureVersion": @132352,
				@"SignerOrganization": @"Apple Inc.",
				@"SignerIdentity": @"Apple iPhone OS Application Signing",
			} mutableCopy];
			NSString *c = container_path(@"MCMPluginKitPluginDataContainer", pid);
			if (c) {
				d[@"Container"] = c;
				d[@"EnvironmentVariables"] = @{@"CFFIXED_USER_HOME": c, @"HOME": c,
				                               @"TMPDIR": [c stringByAppendingPathComponent:@"tmp"]};
			}
			plugins[pid] = d;
		}
	}
	return plugins;
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		int unregister = argc == 3 && strcmp(argv[1], "-u") == 0;
		if (argc != 2 && !unregister) {
			fprintf(stderr, "usage: sweetuicache [-u] /Applications/App.app\n");
			return 2;
		}
		NSString *path = [NSString stringWithUTF8String:argv[argc - 1]];
		dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
		Class ws = NSClassFromString(@"LSApplicationWorkspace");
		if (ws == nil) {
			fprintf(stderr, "sweetuicache: LSApplicationWorkspace not found\n");
			return 1;
		}
		LSApplicationWorkspace *w = [ws defaultWorkspace];
		NSURL *url = [NSURL fileURLWithPath:path];
		if (unregister) {
			BOOL ok = [w unregisterApplication:url];
			printf("sweetuicache: unregister %s -> %s\n", argv[2], ok ? "ok" : "FAILED");
			return ok ? 0 : 1;
		}
		NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
		NSString *bid = info[@"CFBundleIdentifier"];
		if (bid == nil) {
			fprintf(stderr, "sweetuicache: %s has no CFBundleIdentifier\n", argv[1]);
			return 1;
		}
		dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_NOW);
		NSDictionary *plugins = plugins_of(path, bid);
		NSDictionary *dict = @{
			@"ApplicationType": @"System",
			@"CFBundleIdentifier": bid,
			@"CodeInfoIdentifier": bid,
			@"CompatibilityState": @0,
			@"IsDeletable": @NO,
			@"Path": path,
			@"SignerOrganization": @"Apple Inc.",
			@"SignerIdentity": @"Apple iPhone OS Application Signing",
			@"_LSBundlePlugins": plugins,
		};
		BOOL ok = [w registerApplicationDictionary:dict];
		if (!ok) {
			ok = [w registerApplication:url];
		}
		printf("sweetuicache: register %s (%s, %lu extensions) -> %s\n", argv[1], bid.UTF8String, (unsigned long)plugins.count, ok ? "ok" : "FAILED");
		return ok ? 0 : 1;
	}
}
