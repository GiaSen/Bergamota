/*
 * sweetlog [SECONDS] [WORD...]: the unified log over SSH (iOS has no `log` tool). Prints the stored entries of the last
 * SECONDS (default 30) whose process, subsystem, category or message contains any WORD (case-insensitive; no WORD = all),
 * oldest first:   HH:MM:SS.mmm L process[pid] subsystem/category: message
 * L: E error, F fault, i info, d debug, blank default.
 * sweetlog -f SECONDS [WORD...]: follow the live log for SECONDS instead.
 * Through LoggingSupport's OSLogEventStore / OSLogEventLiveStore (what `log show` and `log stream` use on macOS): OSLogStore
 * cannot open the local store on iOS 26, with or without the entitlements. Stream flags: 1 info, 2 debug, 32 signposts; 512
 * hides ordinary messages. SWEETLOG_FLAGS overrides them. iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSMutableArray<NSString *> *words;
static NSDateFormatter *fmt;

static void
emit(id e)
{
	NSString *proc = [e valueForKey:@"process"] ?: @"", *msg = [e valueForKey:@"composedMessage"] ?: @"";
	NSString *sub = [e valueForKey:@"subsystem"] ?: @"", *cat = [e valueForKey:@"category"] ?: @"";
	if (words.count) {
		NSString *hay = [[NSString stringWithFormat:@"%@ %@ %@ %@", proc, sub, cat, msg] lowercaseString];
		BOOL hit = NO;
		for (NSString *w in words)
			if ([hay containsString:w]) { hit = YES; break; }
		if (!hit)
			return;
	}
	char level;
	switch ([[e valueForKey:@"logType"] unsignedIntValue]) {
	case 1: level = 'i'; break;
	case 2: level = 'd'; break;
	case 16: level = 'E'; break;
	case 17: level = 'F'; break;
	default: level = ' '; break;
	}
	printf("%s %c %s[%d] %s/%s: %s\n", [fmt stringFromDate:[e valueForKey:@"date"]].UTF8String, level, proc.UTF8String,
	       [[e valueForKey:@"processIdentifier"] intValue], sub.UTF8String, cat.UTF8String, msg.UTF8String);
	fflush(stdout);
}

static id
send0(id o, NSString *sel)
{
	return ((id (*)(id, SEL))objc_msgSend)(o, NSSelectorFromString(sel));
}

static void
send1(id o, NSString *sel, id a)
{
	((void (*)(id, SEL, id))objc_msgSend)(o, NSSelectorFromString(sel), a);
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		BOOL follow = argc > 1 && !strcmp(argv[1], "-f");
		int a = follow ? 2 : 1;
		double secs = argc > a ? atof(argv[a]) : 30;
		const char *fl = getenv("SWEETLOG_FLAGS");
		unsigned long long flags = fl ? strtoull(fl, NULL, 0) : 3;
		words = [NSMutableArray array];
		for (int i = a + 1; i < argc; i++)
			[words addObject:[@(argv[i]) lowercaseString]];
		fmt = [NSDateFormatter new];
		fmt.dateFormat = @"HH:mm:ss.SSS";
		if (!dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW)) {
			fprintf(stderr, "sweetlog: %s\n", dlerror());
			return 1;
		}
		__block id stream = nil;
		__block BOOL done = NO;
		void (^handler)(id) = ^(id e) { emit(e); };
		void (^ended)(unsigned, id) = ^(unsigned reason, id position) { done = YES; };
		id store = follow ? send0(NSClassFromString(@"OSLogEventLiveStore"), @"liveLocalStore")
		                  : send0(NSClassFromString(@"OSLogEventStore"), @"localStore");
		if (!store) {
			fprintf(stderr, "sweetlog: no log store\n");
			return 1;
		}
		send1(store, @"prepareWithCompletionHandler:", ^(id source, NSError *err) {
			if (!source) {
				fprintf(stderr, "sweetlog: %s\n", err.description.UTF8String);
				done = YES;
				return;
			}
			stream = ((id (*)(id, SEL, id))objc_msgSend)(follow ? [NSClassFromString(@"OSLogEventLiveStream") alloc]
			                                                    : [NSClassFromString(@"OSLogEventStream") alloc],
			                                             NSSelectorFromString(follow ? @"initWithLiveSource:" : @"initWithSource:"), source);
			send1(stream, @"setEventHandler:", handler);
			send1(stream, @"setInvalidationHandler:", ended);
			((void (*)(id, SEL, unsigned long long))objc_msgSend)(stream, NSSelectorFromString(@"setFlags:"), flags);
			if (follow)
				send0(stream, @"activate");
			else
				send1(stream, @"activateStreamFromDate:", [NSDate dateWithTimeIntervalSinceNow:-secs]);
		});
		NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs];
		while (!done && (!follow || end.timeIntervalSinceNow > 0))
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
	}
	return 0;
}
