#include "common/native/SupportedBuild.h"
#import "features/custom-pipeline-bundles/CustomPipelineBundles.h"
#include "common/native/CodePatch.h"
#include "common/Feature.h"
#include <atomic>
#include <dlfcn.h>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <unordered_map>

// How the pieces are made and read (the contract is in
// CustomPipelineBundles.h):
//
// Programs. RenderStage::LoadEngineShader builds an ls::Path from BG3's
// default shader path and the file name, then asks
// ResourceManager::InstantiateShader, whose ShaderManager caches programs by
// the path's string. DataLoader::CreateShader(Path) is the uncached step under
// that cache: it reads the .bshd and calls GPUDevice::CreateShader, which
// allocates a 0x50-byte entry in the device's program container, looks each
// stage name up in Core.metallib then Materials.metallib, and stores the
// resulting functions (+1 retained) in the entry. Calling it directly gives a
// program no other caller shares; its replaced stages are then swapped in the
// entry. An entry hook on it records each program's path.
//
// Depth-stencil states. GPUDevice::CreateDepthState builds a Metal descriptor
// on its stack and keeps only the Metal state, so an entry hook records each
// state's arguments as BG3 makes it.
//
// Blend states keep their settings in their entry (Metal makes blending part
// of the pipeline), and rasterizer states are a malloc'd struct, so both are
// read directly.
namespace Native = BG3MFXBuild::CustomPipelineBundles;
namespace Layout = BG3MFXBuild::CustomPipelineBundles::Layout;

namespace {
// ls::_StringView<char>.
struct StringView { const char *data; uint32_t length; };
// ls::Path is 16 bytes; BG3's own destructor frees it. The extra room only
// guards against a larger layout.
struct alignas(16) Path { uint8_t bytes[64]; };
// rf::StencilOpDesc, passed by value.
struct StencilOpDesc { uint8_t fail, depthFail, pass, compare; };
static_assert(sizeof(StencilOpDesc) == 4, "CreateDepthState reads four bytes of each");
using MakePath = void (*)(Path *, int root, const void *prefix, const StringView *);
using DestroyPath = void (*)(Path *);
using CreateShader = uint64_t (*)(const Path *);
using CreateDepthState = uint64_t (*)(void *device, bool depth, bool write, uint32_t compare, bool stencil,
    uint8_t readMask, uint8_t writeMask, StencilOpDesc front, StencilOpDesc back);
using CreateBlendState = uint64_t (*)(void *device, uint32_t srcRGB, uint32_t dstRGB, uint32_t rgbOp, uint32_t writeMask,
    uint32_t srcAlpha, uint32_t dstAlpha, uint32_t alphaOp);
using CreateRasterizerState = const void *(*)(uint32_t cull, uint32_t fill, bool scissor, bool depthBias, bool depthClip);

// Set at install; the test sets stand-ins. The create functions are BG3's
// originals, past the entry hooks.
MakePath makePath;
DestroyPath destroyPath;
CreateShader createShader;
CreateDepthState createDepthState;
CreateBlendState createBlendState;
CreateRasterizerState createRasterizerState;
void *const *rendererData;       // (anonymous)::s_Data; +0x2128 is the GPU device
void *const *defaultShaderPath;  // RendererBase::s_DefaultShaderPath, an STDString*
// The device CreateDepthState was called on; s_Data's otherwise.
std::atomic<void *> hookedDevice;

std::mutex libraryLock;
NSMutableDictionary<NSString *, id<MTLLibrary>> *libraries;

// BG3 makes programs and states on loading threads.
std::mutex describeLock;
std::unordered_map<uint64_t, std::string> programPaths;
std::unordered_map<uint64_t, BG3MFXDepthStateDesc> depthStates;
// Created pieces, by their settings.
std::mutex createLock;
std::map<std::string, uint64_t> createdDepthStates, createdBlendStates;
std::map<std::string, const void *> createdRasterizerStates;

template<class T> T read(const void *p, size_t offset) {
    T value; memcpy(&value, static_cast<const char *>(p) + offset, sizeof value); return value;
}
char *gpuDevice() {
    if (void *device = hookedDevice.load(std::memory_order_acquire)) return static_cast<char *>(device);
    void *data = rendererData ? *rendererData : nullptr;
    return data ? read<char *>(data, Layout::DataDevice) : nullptr;
}
// The entry for `handle` in the container at `container`, or null if its
// salt doesn't match the slot's: the lookup GPUDevice::CreateShader
// (0x10640d564) and MetalRenderer's replay make.
char *resolve(char *device, size_t container, size_t entryBytes, uint64_t handle) {
    if (!device || handle == BG3MFXInvalidHandle) return nullptr;
    char *base = device + container;
    const uint32_t index = uint32_t(handle), salt = uint32_t(handle >> 32) & 0x3fffff;
    const uint32_t perPage = read<uint32_t>(base, Layout::PageSize);
    if (!perPage || !salt) return nullptr;
    const uint32_t page = index / perPage, slot = index % perPage;
    const uint32_t *salts = read<const uint32_t *const *>(base, Layout::Salts)[page];
    if (!salts || salts[slot] != salt) return nullptr;
    char *entries = read<char *const *>(base, Layout::Pages)[page];
    return entries ? entries + size_t(slot) * entryBytes : nullptr;
}
// The entry owns its functions at +1, as newFunctionWithName: returns them.
void replaceStage(char *entry, size_t offset, id<MTLFunction> function) {
    void *previous = read<void *>(entry, offset);
    void *next = (void *)CFBridgingRetain(function);
    memcpy(entry + offset, &next, sizeof next);
    if (previous) CFRelease(previous);
}
// An ls::Path's text (Layout::Path*).
std::string pathText(const Path *path) {
    const uint8_t *bytes = path->bytes;
    const int8_t tag = int8_t(bytes[Layout::PathInlineLength]);
    if (tag < 0) {
        const char *text = read<const char *>(bytes, 0);
        const uint32_t length = read<uint32_t>(bytes, Layout::PathHeapLength);
        return text ? std::string(text, length) : std::string();
    }
    return std::string(reinterpret_cast<const char *>(bytes), size_t(tag) < Layout::PathBytes ? size_t(tag) : 0);
}
void recordProgram(uint64_t handle, const Path *path) {
    if (handle == BG3MFXInvalidHandle) return;
    std::string text = pathText(path);
    std::lock_guard<std::mutex> hold(describeLock);
    programPaths[handle] = std::move(text);
}
void recordDepthState(uint64_t handle, const BG3MFXDepthStateDesc &desc) {
    if (handle == BG3MFXInvalidHandle) return;
    std::lock_guard<std::mutex> hold(describeLock);
    depthStates[handle] = desc;
}

uint64_t createShaderHook(const Path *path) {
    const uint64_t handle = createShader(path);
    recordProgram(handle, path);
    return handle;
}
uint64_t createDepthStateHook(void *device, bool depth, bool write, uint32_t compare, bool stencil,
                              uint8_t readMask, uint8_t writeMask, StencilOpDesc front, StencilOpDesc back) {
    hookedDevice.store(device, std::memory_order_release);
    const uint64_t handle = createDepthState(device, depth, write, compare, stencil, readMask, writeMask, front, back);
    recordDepthState(handle, {depth, write, uint8_t(compare), stencil, readMask, writeMask,
        {front.fail, front.depthFail, front.pass, front.compare}, {back.fail, back.depthFail, back.pass, back.compare}});
    return handle;
}

// A cache key from settings, field by field (no padding bytes).
template<class... T> std::string key(T... fields) {
    std::string bytes;
    (bytes.push_back(char(fields)), ...);
    return bytes;
}
NSError *makeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"BG3MFXCustomPipelineBundles" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
}

// Programs.

bool BG3MFXDescribeProgram(BG3MFXProgramID program, BG3MFXProgramDesc *desc) {
    char *entry = resolve(gpuDevice(), Layout::Programs, Layout::ProgramBytes, program.handle);
    if (!entry || !desc) return false;
    // The entry keeps them; borrowed.
    desc->stages.vertex = (__bridge id<MTLFunction>)read<void *>(entry, Layout::Vertex);
    desc->stages.fragment = (__bridge id<MTLFunction>)read<void *>(entry, Layout::Fragment);
    std::lock_guard<std::mutex> hold(describeLock);
    const auto found = programPaths.find(program.handle);
    desc->path = found == programPaths.end() ? nil : @(found->second.c_str());
    return true;
}

id<MTLDevice> BG3MFXMetalDevice(void) {
    char *device = gpuDevice();
    if (!device) return nil;
    id<MTLLibrary> core = (__bridge id<MTLLibrary>)read<void *>(device, Layout::CoreLibrary);
    return core.device;
}

BG3MFXProgramID BG3MFXCreateProgram(const char *baseBshd, const BG3MFXProgramStages &replace, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = makeError(1, message);
        return BG3MFXProgramID{};
    };
    if (!createShader) return fail(@"custom-pipeline-bundles is not installed.");
    if (!baseBshd || !*baseBshd) return fail(@"A program needs a base .bshd.");
    if (!replace.vertex && !replace.fragment) return fail(@"A program needs a stage to replace.");
    char *device = gpuDevice();
    id<MTLDevice> metal = BG3MFXMetalDevice();
    if (!device || !metal) return fail(@"BG3's GPU device doesn't exist yet.");
    // A function from another device, or of another stage, would only fail
    // later, when BG3 builds a pipeline from the program.
    struct Stage { id<MTLFunction> function; MTLFunctionType type; size_t offset; const char *name; };
    const Stage stages[] = {
        {replace.vertex, MTLFunctionTypeVertex, Layout::Vertex, "vertex"},
        {replace.fragment, MTLFunctionTypeFragment, Layout::Fragment, "fragment"},
    };
    for (const Stage &stage : stages) {
        if (!stage.function) continue;
        if (stage.function.device != metal)
            return fail([NSString stringWithFormat:@"The %s function is not from BG3's device.", stage.name]);
        if (stage.function.functionType != stage.type)
            return fail([NSString stringWithFormat:@"%@ is not a %s function.", stage.function.name, stage.name]);
    }

    const StringView name{baseBshd, uint32_t(strlen(baseBshd))};
    Path path;
    makePath(&path, Native::EngineShaderRoot, *defaultShaderPath, &name);
    const uint64_t handle = createShader(&path);
    recordProgram(handle, &path);
    destroyPath(&path);
    if (handle == BG3MFXInvalidHandle)
        return fail([NSString stringWithFormat:@"BG3 could not load %s.", baseBshd]);
    // A failure from here leaves the new program unused; BG3 frees it with
    // the device.
    char *entry = resolve(device, Layout::Programs, Layout::ProgramBytes, handle);
    if (!entry) return fail([NSString stringWithFormat:@"BG3's program container has no entry for %s.", baseBshd]);
    // Replace only stages the base program has, so the binding information
    // describes them.
    for (const Stage &stage : stages)
        if (stage.function && !read<void *>(entry, stage.offset))
            return fail([NSString stringWithFormat:@"%s has no %s stage to replace.", baseBshd, stage.name]);
    for (const Stage &stage : stages)
        if (stage.function) replaceStage(entry, stage.offset, stage.function);
    return BG3MFXProgramID{handle};
}

id<MTLLibrary> BG3MFXFunctionLibrary(const char *name, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = makeError(2, message);
        return (id<MTLLibrary>)nil;
    };
    if (!name || !*name) return fail(@"A function library needs a name.");
    id<MTLDevice> metal = BG3MFXMetalDevice();
    if (!metal) return fail(@"BG3's GPU device doesn't exist yet.");
    NSString *libraryName = @(name);
    std::lock_guard<std::mutex> lock(libraryLock);
    if (id<MTLLibrary> cached = libraries[libraryName]) return cached;
    // Next to the runtime: build/bin/ in development, lib/bg3mfx/ when installed.
    Dl_info info;
    if (!dladdr(reinterpret_cast<const void *>(&BG3MFXFunctionLibrary), &info) || !info.dli_fname)
        return fail(@"Could not find the bg3mfx runtime's directory.");
    NSURL *url = [[[NSURL fileURLWithPath:@(info.dli_fname)] URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:[libraryName stringByAppendingPathExtension:@"metallib"]];
    NSError *loadError = nil;
    id<MTLLibrary> library = [metal newLibraryWithURL:url error:&loadError];
    if (!library) return fail([NSString stringWithFormat:@"Could not load %@: %@", url.path, loadError.localizedDescription]);
    if (!libraries) libraries = [NSMutableDictionary dictionary];
    libraries[libraryName] = library;
    return library;
}

// Depth-stencil states.

bool BG3MFXDescribeDepthState(BG3MFXDepthStateID state, BG3MFXDepthStateDesc *desc) {
    std::lock_guard<std::mutex> hold(describeLock);
    const auto found = depthStates.find(state.handle);
    if (found == depthStates.end() || !desc) return false;
    *desc = found->second;
    return true;
}

BG3MFXDepthStateID BG3MFXGetOrCreateDepthState(const BG3MFXDepthStateDesc &d, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = makeError(3, message);
        return BG3MFXDepthStateID{};
    };
    if (!createDepthState) return fail(@"custom-pipeline-bundles is not installed.");
    if (d.compare > MTLCompareFunctionAlways || d.front.compare > MTLCompareFunctionAlways || d.back.compare > MTLCompareFunctionAlways)
        return fail(@"A compare function is out of range.");
    char *device = gpuDevice();
    if (!device) return fail(@"BG3's GPU device doesn't exist yet.");
    const std::string settings = key(d.depthTest, d.depthWrite, d.compare, d.stencil, d.readMask, d.writeMask,
        d.front.fail, d.front.depthFail, d.front.pass, d.front.compare, d.back.fail, d.back.depthFail, d.back.pass, d.back.compare);
    std::lock_guard<std::mutex> hold(createLock);
    if (const auto found = createdDepthStates.find(settings); found != createdDepthStates.end()) return {found->second};
    const uint64_t handle = createDepthState(device, d.depthTest, d.depthWrite, d.compare, d.stencil, d.readMask, d.writeMask,
        {d.front.fail, d.front.depthFail, d.front.pass, d.front.compare}, {d.back.fail, d.back.depthFail, d.back.pass, d.back.compare});
    if (handle == BG3MFXInvalidHandle) return fail(@"BG3 could not make the depth-stencil state.");
    recordDepthState(handle, d);
    createdDepthStates[settings] = handle;
    return {handle};
}

// Blend states.

bool BG3MFXDescribeBlendState(BG3MFXBlendStateID state, BG3MFXBlendStateDesc *desc) {
    if (!desc) return false;
    if (!state.valid()) {
        // Blending off: Metal's defaults, every channel written.
        *desc = {false, 1, 0, 0, 15, 1, 0, 0};
        return true;
    }
    const char *entry = resolve(gpuDevice(), Layout::BlendStates, Layout::StateBytes, state.handle);
    if (!entry) return false;
    const auto byte = [&](size_t offset) { return read<uint8_t>(entry, offset); };
    *desc = {true, byte(0), byte(1), byte(2), byte(3), byte(4), byte(5), byte(6)};
    return true;
}

BG3MFXBlendStateID BG3MFXGetOrCreateBlendState(const BG3MFXBlendStateDesc &d, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = makeError(4, message);
        return BG3MFXBlendStateID{};
    };
    if (!d.enabled) return {};
    if (!createBlendState) return fail(@"custom-pipeline-bundles is not installed.");
    if (d.srcRGB > 10 || d.dstRGB > 10 || d.srcAlpha > 10 || d.dstAlpha > 10) return fail(@"A blend factor is out of range.");
    if (d.rgbOp > 4 || d.alphaOp > 4) return fail(@"A blend operation is out of range.");
    switch (d.writeMask) {
    case 0: case 1: case 2: case 4: case 7: case 8: case 15: break;
    default: return fail(@"BG3 has no such write mask.");
    }
    char *device = gpuDevice();
    if (!device) return fail(@"BG3's GPU device doesn't exist yet.");
    const std::string settings = key(d.srcRGB, d.dstRGB, d.rgbOp, d.writeMask, d.srcAlpha, d.dstAlpha, d.alphaOp);
    std::lock_guard<std::mutex> hold(createLock);
    if (const auto found = createdBlendStates.find(settings); found != createdBlendStates.end()) return {found->second};
    const uint64_t handle = createBlendState(device, d.srcRGB, d.dstRGB, d.rgbOp, d.writeMask, d.srcAlpha, d.dstAlpha, d.alphaOp);
    if (handle == BG3MFXInvalidHandle) return fail(@"BG3 could not make the blend state.");
    createdBlendStates[settings] = handle;
    return {handle};
}

// Rasterizer states.

bool BG3MFXDescribeRasterizerState(BG3MFXRasterizerState state, BG3MFXRasterizerDesc *desc) {
    if (!state.valid() || !desc) return false;
    const auto byte = [&](size_t offset) { return read<uint8_t>(state.pointer, offset); };
    *desc = {byte(0), byte(1), byte(3) != 0, byte(4) != 0, byte(5) != 0};
    return true;
}

BG3MFXRasterizerState BG3MFXGetOrCreateRasterizerState(const BG3MFXRasterizerDesc &d, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = makeError(5, message);
        return BG3MFXRasterizerState{};
    };
    if (!createRasterizerState) return fail(@"custom-pipeline-bundles is not installed.");
    if (d.cull > 2) return fail(@"The cull mode is out of range.");
    const std::string settings = key(d.cull, d.fill, d.scissor, d.depthBias, d.depthClip);
    std::lock_guard<std::mutex> hold(createLock);
    if (const auto found = createdRasterizerStates.find(settings); found != createdRasterizerStates.end()) return {found->second};
    const void *state = createRasterizerState(d.cull, d.fill, d.scissor, d.depthBias, d.depthClip);
    if (!state) return fail(@"BG3 could not make the rasterizer state.");
    createdRasterizerStates[settings] = state;
    return {state};
}

namespace {
// Moves `address`'s first instruction to `island` and branches it to `hook`;
// the original continues at island + BG3MFXEntryOriginalOffset.
BOOL hookEntry(uintptr_t address, uint32_t expected, uintptr_t island, void *hook, NSString *what, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = makeError(6, [NSString stringWithFormat:message, what]);
        return NO;
    };
    // Root has already checked the executable UUID; also check the word replaced.
    const uint32_t first = *reinterpret_cast<const uint32_t *>(address);
    if (first != expected || !BG3MFXRelocatable(first)) return fail(@"Unsupported %@.");
    for (size_t i = 0; i < BG3MFXEntryIslandBytes; ++i)
        if (*reinterpret_cast<const uint8_t *>(island + i)) return fail(@"The %@ island space is in use.");
    if (!BG3MFXBranchReaches(address, island) || !BG3MFXBranchReaches(island + BG3MFXEntryOriginalOffset + 4, address + 4))
        return fail(@"The %@ island is out of range.");
    // The island first, then the entry that reaches it.
    const auto result = BG3MFXPatchCode({{island, BG3MFXEntryIslandBytes}, {address, 4}}, [&] {
        uint32_t words[BG3MFXEntryIslandBytes / 4];
        BG3MFXEncodeEntryIsland(words, island, address, first, reinterpret_cast<uintptr_t>(hook));
        memcpy(reinterpret_cast<void *>(island), words, sizeof words);
        const uint32_t entry = BG3MFXBranch(address, island);
        memcpy(reinterpret_cast<void *>(address), &entry, 4);
    });
    if (result == BG3MFXCodePatchResult::NotWritable) return fail(@"Could not make %@ writable.");
    return YES;
}

// Hooks program and depth-stencil state creation at install, before BG3's
// renderer makes its own; dependents create from BG3's stage loading or later.
BOOL installCustomPipelineBundles(const BG3MFXFeatureContext &context, NSError **error) {
    const intptr_t slide = context.slide;
    const uintptr_t islands = BG3MFXBuild::HeaderPadding + slide + BG3MFXBuild::Islands::CustomPipelineBundles.offset;
    const uintptr_t shaderIsland = islands, depthIsland = islands + BG3MFXEntryIslandBytes;
    // The hooks call the originals as soon as they are patched in.
    createShader = reinterpret_cast<CreateShader>(shaderIsland + BG3MFXEntryOriginalOffset);
    createDepthState = reinterpret_cast<CreateDepthState>(depthIsland + BG3MFXEntryOriginalOffset);
    if (!hookEntry(Native::CreateShader + slide, Native::CreateShaderFirst, shaderIsland,
                   reinterpret_cast<void *>(createShaderHook), @"program creation", error)) {
        createShader = nullptr, createDepthState = nullptr;
        return NO;
    }
    if (!hookEntry(Native::CreateDepthState + slide, Native::CreateDepthStateFirst, depthIsland,
                   reinterpret_cast<void *>(createDepthStateHook), @"depth-stencil state creation", error)) {
        createDepthState = nullptr;
        return NO;
    }
    createBlendState = reinterpret_cast<CreateBlendState>(Native::CreateBlendState + slide);
    createRasterizerState = reinterpret_cast<CreateRasterizerState>(Native::CreateRasterizerState + slide);
    makePath = reinterpret_cast<MakePath>(Native::MakePath + slide);
    destroyPath = reinterpret_cast<DestroyPath>(Native::DestroyPath + slide);
    rendererData = reinterpret_cast<void *const *>(Native::RendererData + slide);
    defaultShaderPath = reinterpret_cast<void *const *>(Native::DefaultShaderPath + slide);
    return YES;
}
}
BG3MFX_FEATURE(customPipelineBundles, {"custom-pipeline-bundles", nullptr, true, nullptr, installCustomPipelineBundles, nullptr});
