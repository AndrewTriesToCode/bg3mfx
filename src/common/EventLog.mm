#import "common/EventLog.h"
#include <fcntl.h>
#include <mutex>
#include <unistd.h>

namespace {
std::mutex &lock() { static auto *value = new std::mutex; return *value; }
NSFileHandle *output;
NSMutableSet<NSString *> *seen;
constexpr NSUInteger MaxRepeatedLines = 20000;
}

void BG3MFXEventLogOpen(void) {
    std::lock_guard<std::mutex> guard(lock());
    if (output) return;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bg3mfx-trace.jsonl"];
    if (const char *override = getenv("BG3MFX_TRACE")) path = [NSString stringWithUTF8String:override];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
    output = fd >= 0 ? [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES] : nil;
    seen = [NSMutableSet set];
}

void BG3MFXEventLogWrite(NSDictionary *event, bool important) {
    std::lock_guard<std::mutex> guard(lock());
    if (!output || (!important && seen.count >= MaxRepeatedLines)) return;
    NSMutableDictionary *identified = [event mutableCopy];
    identified[@"pid"] = @(getpid());
    if (important) identified[@"time"] = @(NSDate.timeIntervalSinceReferenceDate);
    NSData *data = [NSJSONSerialization dataWithJSONObject:identified options:NSJSONWritingSortedKeys error:nil];
    if (!data) return;
    // Important events carry a timestamp, so each is unique: remembering them
    // grew the set by one entry per frame with Frame Generation or prepass trim.
    if (!important) {
        NSString *key = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if ([seen containsObject:key]) return;
        [seen addObject:key];
    }
    NSMutableData *line = [data mutableCopy];
    [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [output writeData:line];
}
