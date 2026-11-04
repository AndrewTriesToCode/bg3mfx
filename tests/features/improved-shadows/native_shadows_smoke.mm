// Test-only fixtures for improved shadows' Load, Unload and StartRecording
// overrides; no BG3 code or assets are linked. The
// stage is a stand-in laid out as SupportedBuild.h describes. BG3's calls,
// custom-pipeline-bundles and custom-render-stages are stand-ins; the fragment
// functions are real, compiled here on the system device.
#import "features/improved-shadows/ImprovedShadows.mm"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {
void check(bool ok, const char *what) {
    if (!ok) { fprintf(stderr, "native-shadows smoke failed: %s\n", what); exit(1); }
}

// Stand-ins for custom-pipeline-bundles: each clone gets the next handle; `failAt`
// makes that clone (counting from 1) fail.
id<MTLDevice> metal;
std::vector<std::string> bases;
std::vector<id<MTLFunction>> fragments;
uint64_t nextClone = 0x500;
size_t failAt;
}
id<MTLDevice> BG3MFXMetalDevice(void) { return metal; }
void BG3MFXFail(NSString *, NSString *, NSString *) {}
BG3MFXProgramID BG3MFXCreateProgram(const char *base, const BG3MFXProgramStages &replace, NSError **error) {
    bases.push_back(base);
    fragments.push_back(replace.fragment);
    if (bases.size() == failAt) {
        if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"stand-in failure"}];
        return BG3MFXProgramID{};
    }
    return BG3MFXProgramID{nextClone++};
}
BOOL BG3MFXOverrideStageMethod(uint8_t, BG3MFXStageMethod, const char *, void *, void **, NSError **) { return YES; }

namespace {
// A stand-in stage and BG3's calls on it. BG3's Load takes its programs from
// the shader cache by name, so every stage gets the handles from `firstOwn`.
alignas(16) char stages[4][0x2200];
void *owners[4][1];
char sceneGraph[0x100];
uint64_t firstOwn = 0x100;
bool loadResult = true;
std::array<uint64_t, Programs> atUnload;
int unloads;
bool stubLoad(void *stage) {
    std::array<uint64_t, Programs> own;
    for (size_t i = 0; i < Programs; ++i) own[i] = firstOwn + i;
    setPrograms(stage, own);
    return loadResult;
}
void stubUnload(void *stage) { ++unloads; atUnload = programs(stage); }

int lookups;
char gbuffer0;
bool normalPresent = true;
void stubGetTextureSRV(TextureBindingInfo *out, void *graph, uint32_t hash, int32_t slice, int32_t view) {
    ++lookups;
    check(graph == sceneGraph && hash == Native::GBuffer0 && slice == -1 && view == 0, "GetTextureSRV is called as the kernel calls it");
    memset(out, 0, sizeof *out);
    if (normalPresent) { out->texture = &gbuffer0; memset(out->view, 0x5a, sizeof out->view); }
}
int binds;
void *bindList;
Binding bound;
TextureBindingInfo boundInfo;
void stubSetTextureSafe(void *list, Binding binding, const TextureBindingInfo *info) {
    ++binds; bindList = list; bound = binding; boundInfo = *info;
}

void *stageAt(int i) {
    write(stages[i], Layout::SceneGraphOwner, static_cast<void *>(owners[i]));
    owners[i][0] = sceneGraph;
    return stages[i];
}
void *listOf(void *stage) { return static_cast<char *>(stage) + Layout::List; }

// BG3's StartRecording, which schedules the kernel: how many binds were
// recorded before it and the table the kernel would pick from.
int recordings, bindsBeforeRecording;
std::array<uint64_t, Programs> atRecording;
void stubStartRecording(void *stage) {
    ++recordings; bindsBeforeRecording = binds; atRecording = programs(stage);
}
void reset() {
    clonesTried = false;
    ready.store(false);
    cloned = 0;
    bases.clear();
    fragments.clear();
    failAt = 0;
    nextClone = 0x500;
}
}

int main() {
    @autoreleasepool {
        metal = MTLCreateSystemDefaultDevice();
        check(metal != nil, "Metal device");
        originalLoad = stubLoad;
        originalUnload = stubUnload;
        originalStartRecording = stubStartRecording;
        getTextureSRV = stubGetTextureSRV;
        setTextureSafe = stubSetTextureSafe;

        // A clone failure keeps BG3's programs, and the hook only forwards.
        failAt = 5;
        void *stage = stageAt(0);
        check(loadHook(stage), "Load's result is returned");
        const auto own0 = programs(stage);
        check(own0[0] == 0x100 && own0[11] == 0x10b, "BG3's programs stay after a clone failure");
        check(bases.size() == 5, "cloning stops at the failure");
        startRecordingHook(stage);
        check(recordings == 1 && lookups == 0 && binds == 0 && atRecording == own0, "without clones, StartRecording only forwards");
        check(loadHook(stageAt(1)) && bases.size() == 5, "a failed clone is not retried");
        unloadHook(stage);
        unloadHook(stageAt(1));
        check(unloads == 2 && atUnload == programs(stageAt(1)), "Unload without clones sees BG3's programs");

        // Clones are made by the first Load, in Load's row order.
        reset();
        stage = stageAt(0);
        check(loadHook(stage), "Load's result is returned");
        check(bases.size() == Programs, "12 clones");
        const char *expected[] = {
            "Shadows/Generated/DirLight_Cascaded_PCSS_1x2048.bshd", "Shadows/Generated/DirLight_Cascaded_PCSS_4x2048.bshd",
            "Shadows/Generated/DirLight_Cascaded_PCSS_1x1024.bshd", "Shadows/Generated/DirLight_Cascaded_PCF_4x1024.bshd"};
        const size_t expectedAt[] = {0, 3, 4, 11};
        for (size_t i = 0; i < 4; ++i) check(bases[expectedAt[i]] == expected[i], "clone base paths follow Load's rows");
        for (id<MTLFunction> fragment : fragments)
            check(fragment && fragment.functionType == MTLFunctionTypeFragment && fragment.device == metal &&
                [fragment.name isEqualToString:@"BG3MFXImprovedShadows"], "each clone gets a specialized fragment function");
        const auto mine = programs(stage);
        check(mine[0] == 0x500 && mine[11] == 0x50b, "the clones replace BG3's programs");
        const auto own = originals;
        check(own[0] == 0x100 && own[11] == 0x10b && cloned == 1, "BG3's programs are kept");

        // A second stage (another view) shares the clones.
        void *other = stageAt(1);
        check(loadHook(other) && bases.size() == Programs, "the clones are made once");
        check(programs(other) == mine && cloned == 2, "each stage gets the clones");

        // StartRecording records the G-buffer normal at fragment texture 6 on the
        // stage's list before the kernel records.
        binds = lookups = 0;
        startRecordingHook(stage);
        check(lookups == 1 && binds == 1 && bindList == listOf(stage), "the normal is bound on the stage's list");
        check(bindsBeforeRecording == 1, "the bind is recorded before BG3's StartRecording schedules the kernel");
        check(bound.bytes[5] == 6 && bound.bytes[0] == 1, "fragment slot 6");
        for (size_t i : {1, 2, 3, 4, 6, 7, 8}) check(bound.bytes[i] == 0xff, "no other stage's slot");
        check(boundInfo.texture == &gbuffer0 && boundInfo.view[15] == 0x5a, "GetTextureSRV's binding info is passed on");
        check(atRecording == mine, "the kernel picks from the clones");

        // No G-buffer normal: the empty binding info is still bound (BG3
        // binds its default texture for it) and the clones stay.
        normalPresent = false;
        startRecordingHook(other);
        check(binds == 2 && bindList == listOf(other) && boundInfo.texture == nullptr && atRecording == mine,
            "without a normal, the clones draw with an empty bind");
        normalPresent = true;

        // Unload puts BG3's programs back before BG3 releases them.
        unloadHook(stage);
        check(atUnload == own && programs(stage) == own && cloned == 1, "Unload releases BG3's own programs");
        check(programs(other) == mine, "other stages keep their clones");

        // A stage whose programs differ from the clone holders' keeps BG3's,
        // and its Unload leaves them alone.
        firstOwn = 0x200;
        void *odd = stageAt(3);
        check(loadHook(odd) && programs(odd)[0] == 0x200 && cloned == 1, "differing programs keep BG3's");
        unloadHook(odd);
        check(atUnload[0] == 0x200 && cloned == 1, "Unload of a stage without clones changes nothing");
        firstOwn = 0x100;

        // With no stage holding the clones, a new Load's programs are taken.
        unloadHook(other);
        check(atUnload == own && cloned == 0, "the last Unload releases BG3's programs");
        firstOwn = 0x300;
        check(loadHook(odd) && programs(odd) == mine && originals[0] == 0x300, "a new set of programs is taken");
        unloadHook(odd);
        check(atUnload[0] == 0x300 && cloned == 0, "and given back");
        firstOwn = 0x100;

        // A Load that fails doesn't take the clones.
        loadResult = false;
        void *third = stageAt(2);
        check(!loadHook(third) && programs(third)[0] != mine[0] && cloned == 0, "a failed Load keeps BG3's programs");
    }
    printf("native-shadows smoke passed\n");
    return 0;
}
