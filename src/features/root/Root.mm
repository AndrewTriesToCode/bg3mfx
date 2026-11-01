#import "common/Feature.h"
#import "common/EventLog.h"
#import "common/Notice.h"
#include "common/native/SupportedBuild.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <algorithm>
#include <string>
#include <vector>

// The root feature: when the runtime loads, it finds every feature registered
// in this image (common/Feature.h), works out which are enabled, and installs
// them in dependency order. It knows no feature by name.

namespace {
struct Entry {
    const BG3MFXFeature *feature = nullptr;
    std::vector<size_t> requires;
    bool enabled = false, off = false, installed = false, active = false;
    NSString *skipped;  // why an enabled feature is not installed or not active
};

// BG3MFX_FEATURE_<NAME>, with the name in upper case and '-' as '_'.
std::string flag(const char *name) {
    std::string variable = "BG3MFX_FEATURE_";
    for (const char *c = name; *c; ++c) variable += *c == '-' ? '_' : char(toupper(*c));
    return variable;
}

// Every required feature, depth first, before the feature itself. Ties go by
// name, so the order doesn't depend on the link order. Returns false on a cycle.
bool visit(std::vector<Entry> &entries, size_t i, std::vector<int> &state, std::vector<size_t> &order) {
    if (state[i] == 2) return true;
    if (state[i] == 1) return false;
    state[i] = 1;
    for (size_t r : entries[i].requires)
        if (!visit(entries, r, state, order)) return false;
    state[i] = 2;
    order.push_back(i);
    return true;
}

// Resolves, installs and activates `features`. `native` is false outside BG3's
// supported build, with `nativeReason` saying why.
std::vector<Entry> run(std::vector<const BG3MFXFeature *> features, const BG3MFXFeatureContext &context,
                       bool native, NSString *nativeReason) {
    auto report = [&](NSDictionary *event) { if (context.report) context.report(event); };
    std::sort(features.begin(), features.end(), [](auto a, auto b) { return strcmp(a->name, b->name) < 0; });
    std::vector<Entry> entries;
    for (const BG3MFXFeature *feature : features) {
        if (!entries.empty() && strcmp(entries.back().feature->name, feature->name) == 0) {
            report(@{@"event":@"featureDuplicate", @"feature":@(feature->name)});
            continue;
        }
        Entry entry;
        entry.feature = feature;
        entries.push_back(entry);
    }
    auto find = [&](const char *name) -> size_t {
        for (size_t i = 0; i < entries.size(); ++i) if (strcmp(entries[i].feature->name, name) == 0) return i;
        return entries.size();
    };
    for (Entry &entry : entries) {
        for (const char *const *r = entry.feature->requires; r && *r; ++r) {
            size_t index = find(*r);
            if (index == entries.size()) entry.skipped = [NSString stringWithFormat:@"Requires %s, which this runtime does not have.", *r];
            else entry.requires.push_back(index);
        }
        const char *value = getenv(flag(entry.feature->name).c_str());
        entry.off = value && strcmp(value, "0") == 0;
        entry.enabled = !entry.off && ((context.runtimeEnabled && value && strcmp(value, "1") == 0) ||
            (entry.feature->wanted && entry.feature->wanted(context)));
    }
    // Enabling a feature enables what it requires, except a feature turned off
    // with =0 (the player launcher sets every flag to 1, so a player's 0 must
    // win); its dependents are then skipped.
    std::vector<size_t> pending;
    for (size_t i = 0; i < entries.size(); ++i) if (entries[i].enabled) pending.push_back(i);
    while (!pending.empty()) {
        size_t i = pending.back(); pending.pop_back();
        for (size_t r : entries[i].requires) {
            if (entries[r].off && !entries[i].skipped)
                entries[i].skipped = [NSString stringWithFormat:@"Requires %s, which is turned off.", entries[r].feature->name];
            else if (!entries[r].off && !entries[r].enabled) { entries[r].enabled = true; pending.push_back(r); }
        }
    }
    std::vector<int> state(entries.size());
    std::vector<size_t> order;
    for (size_t i = 0; i < entries.size(); ++i) {
        if (!entries[i].enabled || state[i] == 2) continue;
        std::vector<size_t> visited;
        if (!visit(entries, i, state, visited)) {
            // Leave the cycle out; features outside it still install.
            for (size_t j = 0; j < entries.size(); ++j) if (state[j] == 1) { state[j] = 2; entries[j].skipped = @"Its requirements form a cycle."; }
        }
        order.insert(order.end(), visited.begin(), visited.end());
    }
    BG3MFXFeatureContext featureContext = context;
    if (!native) featureContext.slide = 0;
    for (size_t i : order) {
        Entry &entry = entries[i];
        if (!entry.enabled || entry.skipped) continue;
        for (size_t r : entry.requires)
            if (!entries[r].installed) { entry.skipped = [NSString stringWithFormat:@"Requires %s, which is not installed.", entries[r].feature->name]; break; }
        if (!entry.skipped && entry.feature->native && !native) entry.skipped = nativeReason;
        if (entry.skipped) continue;
        NSError *error = nil;
        if (entry.feature->install(featureContext, &error)) entry.installed = true;
        else entry.skipped = error.localizedDescription ?: @"Its installation failed.";
    }
    for (size_t i : order) {
        Entry &entry = entries[i];
        if (!entry.installed) continue;
        for (size_t r : entry.requires)
            if (!entries[r].active) { entry.skipped = [NSString stringWithFormat:@"Requires %s, which is not active.", entries[r].feature->name]; break; }
        if (entry.skipped) continue;
        NSError *error = nil;
        if (!entry.feature->activate || entry.feature->activate(featureContext, &error)) entry.active = true;
        else entry.skipped = error.localizedDescription ?: @"Its activation failed.";
    }
    NSMutableArray *active = [NSMutableArray array];
    NSMutableDictionary *skipped = [NSMutableDictionary dictionary];
    for (size_t i : order) if (entries[i].active) [active addObject:@(entries[i].feature->name)];
    for (const Entry &entry : entries) if (entry.enabled && entry.skipped) {
        skipped[@(entry.feature->name)] = entry.skipped;
        report(@{@"event":@"featureSkipped", @"feature":@(entry.feature->name), @"reason":entry.skipped});
    }
    report(@{@"event":@"features", @"active":active, @"skipped":skipped});
    return entries;
}

#ifndef BG3MFX_ROOT_NO_START
#ifndef BG3MFX_NO_TRACE
void logEvent(NSDictionary *event) { BG3MFXEventLogWrite(event, true); }
void traceEvent(NSDictionary *event) { BG3MFXEventLogWrite(event, false); }
#endif

// Whether this process runs BG3's supported executable, and its slide.
bool supportedBuild(intptr_t &slide, NSString *__strong &reason, NSDictionary *__strong &identity) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) { reason = @"Not running in BG3."; return false; }
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const mach_header *candidate = _dyld_get_image_header(i);
        if (candidate->filetype != MH_EXECUTE) continue;
        if (candidate->cputype != CPU_TYPE_ARM64) break;
        auto header = reinterpret_cast<const mach_header_64 *>(candidate);
        const load_command *command = reinterpret_cast<const load_command *>(header + 1);
        for (uint32_t c = 0; c < header->ncmds; ++c) {
            if (command->cmd == LC_UUID) {
                unsigned char expected[16];
                [[[NSUUID alloc] initWithUUIDString:@BG3MFX_SUPPORTED_ARM64_UUID] getUUIDBytes:expected];
                const unsigned char *uuid = reinterpret_cast<const uuid_command *>(command)->uuid;
                identity = @{@"image":@(_dyld_get_image_name(i)), @"uuid":[[NSUUID alloc] initWithUUIDBytes:uuid].UUIDString};
                if (memcmp(uuid, expected, 16) != 0) break;
                slide = _dyld_get_image_vmaddr_slide(i);
                return true;
            }
            command = reinterpret_cast<const load_command *>(reinterpret_cast<const char *>(command) + command->cmdsize);
        }
        break;
    }
    reason = @"This BG3 build is not supported (BG3MFX supports the ARM64 Steam build " BG3MFX_SUPPORTED_VERSION ").";
    return false;
}

// Before BG3's main, so features install before BG3 builds its menus,
// creates its device or starts its threads. This must be the image's last
// initializer, after every feature file's own static initializers: the
// Makefile links this file last.
__attribute__((constructor)) void start() {
    @autoreleasepool {
#ifndef BG3MFX_NO_TRACE
        BG3MFXEventLogOpen();
        void (*report)(NSDictionary *) = logEvent, (*trace)(NSDictionary *) = traceEvent;
#else
        void (*report)(NSDictionary *) = nullptr, (*trace)(NSDictionary *) = nullptr;
#endif
        intptr_t slide = 0;
        NSString *reason = nil;
        NSDictionary *identity = nil;
        bool native = supportedBuild(slide, reason, identity);
        if (report && identity) report(@{@"event":@"nativeBuild", @"supported":@(native), @"image":identity[@"image"], @"uuid":identity[@"uuid"]});
        Dl_info info{};
        unsigned long size = 0;
        const uint8_t *section = dladdr(reinterpret_cast<const void *>(&start), &info) && info.dli_fbase ?
            getsectiondata(static_cast<const mach_header_64 *>(info.dli_fbase), "__DATA", BG3MFX_FEATURE_SECTION, &size) : nullptr;
        auto registered = reinterpret_cast<const BG3MFXFeature *const *>(section);
        std::vector<const BG3MFXFeature *> features(registered, registered + (section ? size / sizeof *registered : 0));
        BG3MFXFeatureContext context{slide, BG3MFXFeatureEnabled("BG3MFX_ENABLE"), report, trace};
        std::vector<Entry> entries = run(features, context, native, reason);
        // On another BG3 build, say once that the native features are off.
        bool nativeWanted = std::any_of(entries.begin(), entries.end(), [](const Entry &e) { return e.enabled && e.feature->native; });
        if (!native && [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"] && nativeWanted) {
            fprintf(stderr, "BG3MFX could not start: %s\n", reason.UTF8String); fflush(stderr);
            BG3MFXShowNotice(@"BG3MFX could not start", [reason stringByAppendingString:@"\n\nThe game continues without BG3MFX."]);
        }
    }
}
#endif
}
