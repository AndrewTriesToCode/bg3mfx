#pragma once
// Single supported Steam executable. C/Objective-C, C++, and the Python
// development launcher consume these definitions. Addresses below are unslid
// ARM64 virtual addresses; installers retain their instruction/shape guards.
#define BG3MFX_SUPPORTED_VERSION "4.1.1.7631656"
#define BG3MFX_SUPPORTED_SHA256 "d81e0420d9158e6e58c55af62e8490366768d7376a92868d3bf55d05d561519b"
#define BG3MFX_SUPPORTED_ARM64_UUID "3B6F6492-114E-3EA2-BC64-DFDDBD361434"

#ifdef __cplusplus
#include <cstddef>
#include <cstdint>
namespace BG3MFXBuild {
inline constexpr uintptr_t ImageBase = 0x100000000;
inline constexpr uintptr_t HeaderPadding = 0x100004000;
inline constexpr uint32_t HeaderCommandBytes = 0x1b28;
namespace Menu {
inline constexpr uintptr_t ResolveText = 0x1065465e4;
inline constexpr uintptr_t SetQuality = 0x10640df94;
inline constexpr uintptr_t RefreshQuality = 0x103291ef8;
inline constexpr uintptr_t PublishSettings = 0x1032906c4;
inline constexpr uintptr_t TranslationRepository = 0x108b26098;
inline constexpr uintptr_t MakeHandle = 0x106535df4;
inline constexpr uintptr_t AddTranslatedString = 0x106549388;
inline constexpr uintptr_t MakeText = 0x106545cc4;
inline constexpr uintptr_t DestroyHandle = 0x1064d0c60;
inline constexpr uintptr_t DestroyText = 0x106545e94;
inline constexpr uintptr_t AppendComboValue = 0x103294954;
inline constexpr uintptr_t AddTickBox = 0x1030a39bc;
inline constexpr uintptr_t Callbacks = 0x1087ac1a0;
inline constexpr uintptr_t Init = 0x103288fb8;
inline constexpr uintptr_t ApplyCombo = 0x103290180;
}
namespace Temporal {
inline constexpr uintptr_t PostProcessStageVTable = 0x10886b5a0;
inline constexpr uintptr_t FSRStepVTable = 0x10886c380;
inline constexpr uintptr_t Settings = 0x108af4118;
inline constexpr uintptr_t ProjectionLoad = 0x105f8bdc8;
inline constexpr uintptr_t CameraLoad = 0x105f8af84;
inline constexpr uintptr_t VelocityLoad = 0x106253924;
inline constexpr uintptr_t PostProcessMethod = 0x10608f590;
}
namespace ThreadIdling {
inline constexpr uintptr_t WorkerBudget = 0x10655389c;
inline constexpr uintptr_t SchedulerWindowFirst = 0x106551aec;
inline constexpr uintptr_t SchedulerWindowSecond = 0x106551c84;
inline constexpr uintptr_t CapIdleYield = 0x1064d1e94;
inline constexpr uintptr_t WaitYield = 0x106551328;
inline constexpr uintptr_t WaitResume = 0x10655132c;
inline constexpr uintptr_t WaitBlock = 0x1065514b0;
}
namespace Lua {
inline constexpr uintptr_t LongjmpCall = 0x100769e8c;
inline constexpr uintptr_t SetjmpCall = 0x100769f64;
}
namespace ServerPacing {
inline constexpr uintptr_t TickStart = 0x100c8ff0c;
inline constexpr uintptr_t World = 0x100c8ffa0;
inline constexpr uintptr_t TickEnd = 0x100c9002c;
inline constexpr uintptr_t Cap = 0x100c90090;
inline constexpr uintptr_t ProcessTarget = 0x1064bd494;
inline constexpr uintptr_t WorldTarget = 0x10638ec08;
inline constexpr uintptr_t GettimeofdayTarget = 0x1077cce0c;
inline constexpr uintptr_t CapTarget = 0x1064d1b8c;
}
namespace Shadows {
inline constexpr uintptr_t FirstStageAdd = 0x105d1a7c8;
inline constexpr uintptr_t SecondStageAdd = 0x105d1a818;
inline constexpr uintptr_t StageType = 0x10789ffc3;
}

namespace Menu::Layout {
inline constexpr size_t Items = 0x30;
inline constexpr size_t ItemCount = 0x3c;
inline constexpr size_t ItemID = 0x88;
inline constexpr size_t CheckboxValue = 0xa8;
inline constexpr size_t ItemEnabled = 0x2c;
inline constexpr size_t EnabledObservers = 0x78;
inline constexpr size_t EnabledObserverCount = 0x84;
inline constexpr size_t ObserverStride = 0x48;
inline constexpr size_t ComboCount = 0x9c;
inline constexpr size_t ComboItems = 0x90;
inline constexpr size_t ComboItemStride = 0x24;
inline constexpr size_t ComboItemValue = 0x20;
inline constexpr size_t ComboSelection = 0xd0;
inline constexpr size_t SelectionCallback = 0x38;
inline constexpr size_t SelectionObservers = 0xc0;
inline constexpr size_t SelectionObserverCount = 0xcc;
inline constexpr size_t NativeUpscalingType = 0xf7;
inline constexpr size_t NativeQuality = 0xf8;
inline constexpr size_t SettingsStorage = 0x60;
inline constexpr size_t CallbackManager = 0x18;
inline constexpr size_t CapturedManager = 0x50;
inline constexpr size_t ItemType = 8, VTable = 0, ObserverContext = 8, TranslationMap = 8;
inline constexpr size_t InitSlot = 4, ApplyComboSlot = 7;
}

namespace Temporal::Layout {
inline constexpr size_t ViewStages = 0x20;
inline constexpr size_t ViewStageCount = 0x2c;
inline constexpr size_t Enabled = 0x18;
inline constexpr size_t StageSteps = 0x2150;
inline constexpr size_t StageStepCount = 0x215c;
inline constexpr size_t ViewFrame = 0x2050;
inline constexpr size_t ViewCamera = 0x21d8;
inline constexpr size_t ViewSize = 0x2180;
inline constexpr size_t CameraUnjittered = 0xa;
inline constexpr size_t SettingsQuality = 0x98;
inline constexpr size_t ClassifierMethodSlot = 0x10;
inline constexpr size_t VTable = 0, FrameIndex = 8, FrameIndexOffset = 12;
inline constexpr size_t JitterIslandStride = 64;
}

namespace ServerPacing::Layout {
inline constexpr size_t Target = 0x18, Debt = 0x28;
inline constexpr size_t WorkerTarget = 0x98, WorkerDebt = 0xa8;
}

// Reserved half-open ranges relative to HeaderPadding. Validate every island
// against its own zero bytes before patching, in addition to these overlap checks.
struct Island { size_t offset, bytes; };
namespace Islands {
inline constexpr Island Temporal{0x000, 3 * 64};
inline constexpr Island Lua{0x700, 32};
inline constexpr Island ServerPacing{0x800, 4 * 24};
inline constexpr Island ThreadWait{0x9a0, 32};
inline constexpr Island ThreadIdle{0x9c0, 16};
inline constexpr Island All[] = {Temporal, Lua, ServerPacing, ThreadWait, ThreadIdle};
constexpr bool valid(const Island *ranges, size_t count) {
    for (size_t i=0; i<count; ++i) {
        const Island current = ranges[i];
        if (!current.bytes || current.offset % 4 || current.bytes % 4 ||
            current.offset > 0x4000 || current.bytes > 0x4000 - current.offset) return false;
        for (size_t j=0; j<i; ++j)
            if (current.offset < ranges[j].offset + ranges[j].bytes && ranges[j].offset < current.offset + current.bytes) return false;
    }
    return true;
}
static_assert(valid(All,sizeof(All)/sizeof(All[0])), "Native branch-island reservations must be aligned, disjoint, and within header padding");
}
}
#endif
