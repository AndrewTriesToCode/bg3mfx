#include "common/native/SupportedBuild.h"
#import "features/improved-shadows/ImprovedShadows.h"
#import "features/custom-render-stages/CustomRenderStages.h"
#import "features/custom-pipeline-bundles/CustomPipelineBundles.h"
#include "features/improved-shadows/ImprovedShadowsShader.h"
#include <os/log.h>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>

// How it works (native-shadows-plan.md):
//
// CascadedShadowMaskStage::Load loads 12 programs, one per quality row and
// cascade count, and the stage's kernel copies one to Current each frame for
// its single full-screen draw. bg3mfx makes 12 clones of them, BG3's programs
// with bg3mfx's fragment function, once, and its Load override puts them in
// place of BG3's in every shadow mask stage. Load takes its programs from
// BG3's shader cache by name, so every stage holds the same 12; Unload puts
// them back first, so BG3 releases exactly what it loaded and never the
// shared clones. BG3 then builds and binds the pipeline itself. The fragment
// function also reads the G-buffer normal at texture 6, which BG3 doesn't
// bind for this pass: the StartRecording override binds it at the head of the
// stage's list, before the kernel records. The kernel's subpass resets
// MetalRenderer's highest bound slot but keeps its texture table, and the
// kernel's own binds (0-5 and 36) raise that slot again, so PreDraw sends
// slot 6 with them. With no G-buffer normal (Bink videos), SetTextureSafe
// binds BG3's transparent default texture and the shader drops the normal
// offset.
namespace Native = BG3MFXBuild::Shadows;
namespace Layout = BG3MFXBuild::Shadows::Layout;

namespace {
constexpr size_t Programs = 12, Cascades = 4;
// The rows Load fills, in order (Load's filter and map-size tables).
struct Row { const char *filter; int mapSize; bool pcss; };
constexpr Row Rows[] = {{"PCSS", 2048, true}, {"PCSS", 1024, true}, {"PCF", 1024, false}};
static_assert(sizeof Rows / sizeof Rows[0] * Cascades == Programs, "3 rows of 4 cascade counts");

// rf::TextureBindingInfo: the Texture* (null if not found), then a view
// description.
struct TextureBindingInfo { void *texture; uint8_t view[16]; };
static_assert(sizeof(TextureBindingInfo) == 24, "GetTextureSRV writes 24 bytes");
// rf::sb::Binding: a slot per stage, 0xff for none; +0x05 is the fragment
// slot. Byte 0 is 1 in every call BG3 makes; MetalRenderer::SetTexture
// doesn't read it.
struct Binding { uint8_t bytes[9]; };
constexpr Binding FragmentTexture6 = {{0x01, 0xff, 0xff, 0xff, 0xff, 6, 0xff, 0xff, 0xff}};

using Load = bool (*)(void *stage);
using Unload = void (*)(void *stage);
using StartRecording = void (*)(void *stage);
using GetTextureSRV = void (*)(TextureBindingInfo *out, void *sceneGraph, uint32_t hash, int32_t slice, int32_t view);
using SetTextureSafe = void (*)(void *list, Binding binding, const TextureBindingInfo *info);

// Set at install (BG3's) and activation (the originals); the test sets stand-ins.
Load originalLoad;
Unload originalUnload;
StartRecording originalStartRecording;
GetTextureSRV getTextureSRV;
SetTextureSafe setTextureSafe;
void (*reportEvent)(NSDictionary *);

// The clones, made by the first Load; never released. `ready` publishes them
// to StartRecording. `lock` guards the rest, which only Load and Unload use.
std::mutex lock;
bool clonesTried;
std::atomic<bool> ready{false};
std::array<uint64_t, Programs> clones;
// BG3's programs, the same in every stage, and how many stages hold the
// clones in their place.
std::array<uint64_t, Programs> originals;
int cloned;

os_log_t shadowLog() {
    static os_log_t log = os_log_create("com.bg3mfx", "shadow");
    return log;
}
template<class T> T read(const void *p, size_t offset) {
    T value; memcpy(&value, static_cast<const char *>(p) + offset, sizeof value); return value;
}
template<class T> void write(void *p, size_t offset, T value) { memcpy(static_cast<char *>(p) + offset, &value, sizeof value); }

std::array<uint64_t, Programs> programs(void *stage) {
    std::array<uint64_t, Programs> result;
    memcpy(result.data(), static_cast<char *>(stage) + Layout::Programs, sizeof result);
    return result;
}
void setPrograms(void *stage, const std::array<uint64_t, Programs> &values) {
    memcpy(static_cast<char *>(stage) + Layout::Programs, values.data(), sizeof values);
}

// Called with `lock` held. Compiles the fragment function for each row and
// cascade count on BG3's device and clones BG3's program around it.
bool makeClones() {
    if (clonesTried) return ready.load(std::memory_order_relaxed);
    clonesTried = true;
    auto fail = [](NSString *message) {
        os_log(shadowLog(), "improved shadows: BG3's shaders kept (%{public}@)", message);
        if (reportEvent) reportEvent(@{@"event":@"shadowClones", @"ready":@NO, @"error":message ?: @""});
        return false;
    };
    id<MTLDevice> device = BG3MFXMetalDevice();
    if (!device) return fail(@"BG3's GPU device doesn't exist yet");
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:@(BG3MFXImprovedShadowsSource) options:nil error:&error];
    if (!library) return fail(error.localizedDescription);
    for (size_t row = 0; row < sizeof Rows / sizeof Rows[0]; ++row) {
        for (int cascades = 1; cascades <= int(Cascades); ++cascades) {
            MTLFunctionConstantValues *values = [MTLFunctionConstantValues new];
            float mapSize = float(Rows[row].mapSize);
            bool pcss = Rows[row].pcss;
            [values setConstantValue:&cascades type:MTLDataTypeInt atIndex:0];
            [values setConstantValue:&mapSize type:MTLDataTypeFloat atIndex:1];
            [values setConstantValue:&pcss type:MTLDataTypeBool atIndex:2];
            id<MTLFunction> fragment = [library newFunctionWithName:@"BG3MFXImprovedShadows" constantValues:values error:&error];
            if (!fragment) return fail(error.localizedDescription);
            char base[96];
            snprintf(base, sizeof base, "Shadows/Generated/DirLight_Cascaded_%s_%dx%d.bshd", Rows[row].filter, cascades, Rows[row].mapSize);
            BG3MFXProgramStages stages;
            stages.fragment = fragment;
            const BG3MFXProgramID clone = BG3MFXCreateProgram(base, stages, &error);
            if (!clone.valid()) return fail(error.localizedDescription);
            clones[row * Cascades + size_t(cascades - 1)] = clone.handle;
        }
    }
    ready.store(true, std::memory_order_release);
    os_log(shadowLog(), "improved shadows: ready");
    if (reportEvent) reportEvent(@{@"event":@"shadowClones", @"ready":@YES});
    return true;
}

bool loadHook(void *stage) {
    const bool loaded = originalLoad(stage);
    if (!loaded) return loaded;
    std::lock_guard<std::mutex> hold(lock);
    if (!makeClones()) return loaded;
    const auto own = programs(stage);
    if (cloned && own != originals) {
        // Not seen: BG3's cache gave this stage other programs than the
        // stages holding the clones, so Unload couldn't put them back.
        os_log(shadowLog(), "improved shadows: BG3's shaders kept for a stage (its programs differ)");
        return loaded;
    }
    originals = own;
    ++cloned;
    setPrograms(stage, clones);
    return loaded;
}

void unloadHook(void *stage) {
    {
        std::lock_guard<std::mutex> hold(lock);
        if (cloned && programs(stage) == clones) {
            setPrograms(stage, originals);
            --cloned;
        }
    }
    originalUnload(stage);
}

// Before BG3's StartRecording schedules the kernel: the G-buffer normal at
// the head of the stage's list. SetTextureSafe records it, or binds it at
// once on an immediate list, and binds BG3's transparent default texture when
// GetTextureSRV finds none. A stage that kept BG3's programs ignores slot 6.
void startRecordingHook(void *stage) {
    if (ready.load(std::memory_order_acquire)) {
        void *list = static_cast<char *>(stage) + Layout::List;
        void *sceneGraph = read<void *>(read<void *>(stage, Layout::SceneGraphOwner), 0);
        TextureBindingInfo normal{};
        getTextureSRV(&normal, sceneGraph, Native::GBuffer0, -1, 0);
        setTextureSafe(list, FragmentTexture6, &normal);
    }
    originalStartRecording(stage);
}

}

BOOL BG3MFXInstallImprovedShadows(const BG3MFXFeatureContext &context, NSError **error) {
    getTextureSRV = reinterpret_cast<GetTextureSRV>(Native::GetTextureSRV + context.slide);
    setTextureSafe = reinterpret_cast<SetTextureSafe>(Native::SetTextureSafe + context.slide);
    reportEvent = context.report;
    // The overrides apply when custom-render-stages activates; until Load makes
    // the clones, StartRecording only forwards.
    static const char *const feature = "improved-shadows";
    return BG3MFXOverrideStageMethod(Native::StageType, BG3MFXStageMethod::Load, feature,
               (void *)loadHook, reinterpret_cast<void **>(&originalLoad), error) &&
        BG3MFXOverrideStageMethod(Native::StageType, BG3MFXStageMethod::Unload, feature,
            (void *)unloadHook, reinterpret_cast<void **>(&originalUnload), error) &&
        BG3MFXOverrideStageMethod(Native::StageType, BG3MFXStageMethod::StartRecording, feature,
            (void *)startRecordingHook, reinterpret_cast<void **>(&originalStartRecording), error);
}

namespace {
const char *const improvedShadowsRequires[] = {"custom-render-stages", "custom-pipeline-bundles", nullptr};
}
// Native: it calls BG3's functions at the supported build's addresses.
BG3MFX_FEATURE(improvedShadows, {"improved-shadows", improvedShadowsRequires, true, nullptr,
    BG3MFXInstallImprovedShadows, nullptr});
