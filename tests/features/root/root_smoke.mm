// Root's resolution and install order, with stand-in features; nothing is
// patched. The constructor is left out, so only `run` is exercised.
#define BG3MFX_ROOT_NO_START 1
#import "features/root/Root.mm"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {
std::vector<std::string> calls;
std::vector<NSDictionary *> events;
std::vector<std::string> failInstall, failActivate;
intptr_t seenSlide = -1;
void check(bool ok, const char *what) {
    if (!ok) { fprintf(stderr, "root smoke failed: %s\n", what); exit(1); }
}
bool contains(const std::vector<std::string> &list, const std::string &name) {
    return std::find(list.begin(), list.end(), name) != list.end();
}
// One stand-in per name, recording its calls.
template<int N> struct Fake {
    static const char *name;
    static BOOL install(const BG3MFXFeatureContext &context, NSError **error) {
        calls.push_back(std::string("install ") + name);
        seenSlide = context.slide;
        if (!contains(failInstall, name)) return YES;
        *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"install failed"}];
        return NO;
    }
    static BOOL activate(const BG3MFXFeatureContext &, NSError **error) {
        calls.push_back(std::string("activate ") + name);
        if (!contains(failActivate, name)) return YES;
        *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"activate failed"}];
        return NO;
    }
};
template<int N> const char *Fake<N>::name;
template<int N> BG3MFXFeature feature(const char *name, const char *const *requires, bool native = false,
                                      bool (*wanted)(const BG3MFXFeatureContext &) = nullptr) {
    Fake<N>::name = name;
    return {name, requires, native, wanted, Fake<N>::install, Fake<N>::activate};
}
}
void BG3MFXEventLogWrite(NSDictionary *event, bool) { events.push_back(event); }
namespace {
std::vector<Entry> runAll(std::vector<const BG3MFXFeature *> features, bool runtime = true, bool native = true) {
    calls.clear(); events.clear(); seenSlide = -1;
    BG3MFXFeatureContext context{0x1000, runtime};
    return run(features, context, native, @"Not the supported build.");
}
NSDictionary *summary() {
    for (NSDictionary *event : events) if ([event[@"event"] isEqualToString:@"features"]) return event;
    return nil;
}
void flags(std::initializer_list<const char *> names) {
    for (const char *name : {"BG3MFX_FEATURE_PROVIDER", "BG3MFX_FEATURE_CONSUMER", "BG3MFX_FEATURE_ALPHA",
                             "BG3MFX_FEATURE_NATIVE_PATCH", "BG3MFX_FEATURE_LOOP_A", "BG3MFX_FEATURE_ORPHAN"}) unsetenv(name);
    for (const char *name : names) setenv(name, "1", 1);
}
bool alwaysWanted(const BG3MFXFeatureContext &) { return true; }
}

int main() {
    @autoreleasepool {
        static const char *const needsProvider[] = {"provider", nullptr};
        static const char *const needsConsumer[] = {"consumer", nullptr};
        static const char *const needsLoopA[] = {"loop-a", nullptr};
        static const char *const needsLoopB[] = {"loop-b", nullptr};
        static const char *const needsMissing[] = {"missing", nullptr};
        static const char *const needsNative[] = {"native-patch", nullptr};
        const BG3MFXFeature provider = feature<0>("provider", nullptr);
        const BG3MFXFeature consumer = feature<1>("consumer", needsProvider);
        const BG3MFXFeature alpha = feature<2>("alpha", nullptr);
        const BG3MFXFeature nativePatch = feature<3>("native-patch", nullptr, true);
        const BG3MFXFeature onNative = feature<4>("on-native", needsNative);
        const BG3MFXFeature loopA = feature<5>("loop-a", needsLoopB);
        const BG3MFXFeature loopB = feature<6>("loop-b", needsLoopA);
        const BG3MFXFeature orphan = feature<7>("orphan", needsMissing);
        const BG3MFXFeature always = feature<8>("always", nullptr, false, alwaysWanted);
        const BG3MFXFeature top = feature<9>("top", needsConsumer);

        // Off without a flag; a flag only counts with BG3MFX_ENABLE=1.
        flags({});
        runAll({&provider, &consumer});
        check(calls.empty(), "no flags, nothing installs");
        flags({"BG3MFX_FEATURE_PROVIDER"});
        runAll({&provider}, false);
        check(calls.empty(), "flags need the runtime");

        // Enabling a feature enables what it requires, installed first; every
        // install comes before any activation. The registration order doesn't matter.
        flags({"BG3MFX_FEATURE_CONSUMER"});
        runAll({&consumer, &provider});
        check((calls == std::vector<std::string>{"install provider", "install consumer", "activate provider", "activate consumer"}),
              "dependency order, installs before activations");
        check(seenSlide == 0x1000, "context slide");
        check([summary()[@"active"] isEqualToArray:(@[@"provider", @"consumer"])], "summary lists active features");
        // Requirements of requirements, and independent features by name.
        flags({"BG3MFX_FEATURE_ALPHA"}); setenv("BG3MFX_FEATURE_TOP", "1", 1);
        runAll({&top, &alpha, &consumer, &provider});
        unsetenv("BG3MFX_FEATURE_TOP");
        check((calls == std::vector<std::string>{"install alpha", "install provider", "install consumer", "install top",
                                                 "activate alpha", "activate provider", "activate consumer", "activate top"}),
              "transitive requirements, ties by name");

        // An explicit 0 keeps a requirement off and skips its dependents.
        flags({"BG3MFX_FEATURE_CONSUMER"}); setenv("BG3MFX_FEATURE_PROVIDER", "0", 1);
        runAll({&provider, &consumer});
        check(calls.empty() && [summary()[@"skipped"][@"consumer"] isEqualToString:@"Requires provider, which is turned off."],
              "a requirement turned off");

        // `wanted` enables without a flag, with or without the runtime.
        flags({});
        runAll({&always}, false);
        check((calls == std::vector<std::string>{"install always", "activate always"}), "wanted");

        // A native feature needs the supported build, and so do its dependents;
        // other features still install, with a zero slide.
        flags({"BG3MFX_FEATURE_ALPHA"}); setenv("BG3MFX_FEATURE_ON_NATIVE", "1", 1);
        runAll({&alpha, &nativePatch, &onNative}, true, false);
        unsetenv("BG3MFX_FEATURE_ON_NATIVE");
        check((calls == std::vector<std::string>{"install alpha", "activate alpha"}), "native features skipped off the supported build");
        check(seenSlide == 0, "no slide off the supported build");
        check([summary()[@"skipped"][@"native-patch"] isEqualToString:@"Not the supported build."] &&
              [summary()[@"skipped"][@"on-native"] hasPrefix:@"Requires native-patch"], "native skip reasons");

        // A failed install skips its dependents; a failed activation leaves
        // its dependents installed but not activated.
        flags({"BG3MFX_FEATURE_CONSUMER"});
        failInstall = {"provider"};
        runAll({&provider, &consumer});
        check((calls == std::vector<std::string>{"install provider"}), "failed install skips dependents");
        check([summary()[@"skipped"][@"provider"] isEqualToString:@"install failed"], "install failure reason");
        failInstall = {}; failActivate = {"provider"};
        runAll({&provider, &consumer});
        check((calls == std::vector<std::string>{"install provider", "install consumer", "activate provider"}), "failed activation");
        check([summary()[@"active"] count] == 0 && [summary()[@"skipped"][@"consumer"] hasPrefix:@"Requires provider"], "nothing active");
        failActivate = {};

        // Cycles and unknown requirements are skipped; the rest still installs.
        flags({"BG3MFX_FEATURE_LOOP_A", "BG3MFX_FEATURE_ORPHAN", "BG3MFX_FEATURE_ALPHA"});
        runAll({&loopA, &loopB, &orphan, &alpha});
        check((calls == std::vector<std::string>{"install alpha", "activate alpha"}), "cycle and unknown requirement skipped");
        check([summary()[@"skipped"][@"loop-a"] isEqualToString:@"Its requirements form a cycle."] &&
              [summary()[@"skipped"][@"loop-b"] isEqualToString:@"Its requirements form a cycle."] &&
              [summary()[@"skipped"][@"orphan"] hasPrefix:@"Requires missing"], "cycle and unknown reasons");

        // A second registration under a taken name is ignored.
        flags({"BG3MFX_FEATURE_PROVIDER"});
        const BG3MFXFeature again = feature<10>("provider", nullptr);
        runAll({&provider, &again});
        check(calls.size() == 2, "one install per name");
        check(std::any_of(events.begin(), events.end(), [](NSDictionary *e) { return [e[@"event"] isEqualToString:@"featureDuplicate"]; }),
              "duplicate reported");

        check(flag("custom-render-stages") == "BG3MFX_FEATURE_CUSTOM_RENDER_STAGES", "flag names");
        puts("Root: flags with the runtime, wanted features, requirements first and enabled with their dependents, "
             "installs before activations, native, install, activation, cycle and unknown-requirement skips passed.");
    }
}
