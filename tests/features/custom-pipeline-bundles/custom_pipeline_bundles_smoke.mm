// Test-only fixtures for custom-pipeline-bundles; no BG3 code or assets are
// linked. The GPU device, its containers and the native calls are stand-ins
// laid out as SupportedBuild.h describes; the functions are real, compiled
// here on the system device.
#import "features/custom-pipeline-bundles/CustomPipelineBundles.mm"
#import "common/native/CodePatch.mm"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {
void check(bool ok, const char *what) {
    if (!ok) { fprintf(stderr, "custom-pipeline-bundles smoke failed: %s\n", what); exit(1); }
}

// Stand-in device: each container has two pages of four entries.
constexpr uint32_t PerPage = 4;
alignas(16) char device[0x900];
alignas(16) char programEntries[2][PerPage * Layout::ProgramBytes];
alignas(16) char blendEntries[2][PerPage * Layout::StateBytes];
uint32_t programSalts[2][PerPage], blendSalts[2][PerPage];
char *programPages[2] = {programEntries[0], programEntries[1]};
char *blendPages[2] = {blendEntries[0], blendEntries[1]};
uint32_t *programSaltPages[2] = {programSalts[0], programSalts[1]};
uint32_t *blendSaltPages[2] = {blendSalts[0], blendSalts[1]};
void *data[(Layout::DataDevice / sizeof(void *)) + 1];
void *dataPointer;
const char prefix[] = "prefix";
void *prefixPointer = const_cast<char *>(prefix);

void container(size_t offset, void *pages, void *salts) {
    uint32_t perPage = PerPage;
    memcpy(device + offset + Layout::PageSize, &perPage, sizeof perPage);
    memcpy(device + offset + Layout::Pages, &pages, sizeof pages);
    memcpy(device + offset + Layout::Salts, &salts, sizeof salts);
}

// Stand-in native calls: what they were given, and what they return.
std::string pathName;
int pathRoot = -1, pathsMade = 0, pathsDestroyed = 0;
const void *pathPrefix;
uint64_t nextHandle;
// MakePath stores "<prefix>/<name>" as BG3's Path would: inline when it fits.
std::string heapPath;
void stubMakePath(Path *path, int root, const void *p, const StringView *name) {
    ++pathsMade; pathRoot = root; pathPrefix = p; pathName.assign(name->data, name->length);
    memset(path->bytes, 0, sizeof path->bytes);
    heapPath = std::string(static_cast<const char *>(p)) + "/" + pathName;
    if (heapPath.size() < Layout::PathBytes) {
        memcpy(path->bytes, heapPath.data(), heapPath.size());
        path->bytes[Layout::PathInlineLength] = uint8_t(heapPath.size());
    } else {
        const char *text = heapPath.c_str();
        const uint32_t length = uint32_t(heapPath.size());
        memcpy(path->bytes, &text, sizeof text);
        memcpy(path->bytes + Layout::PathHeapLength, &length, sizeof length);
        path->bytes[Layout::PathInlineLength] = 0x80;
    }
}
void stubDestroyPath(Path *) { ++pathsDestroyed; }
uint64_t stubCreateShader(const Path *) { return nextHandle; }
struct DepthCall { void *device; bool depth, write; uint32_t compare; bool stencil; uint8_t read, write2; StencilOpDesc front, back; };
std::vector<DepthCall> depthCalls;
uint64_t stubCreateDepthState(void *d, bool depth, bool write, uint32_t compare, bool stencil, uint8_t read, uint8_t writeMask,
                              StencilOpDesc front, StencilOpDesc back) {
    depthCalls.push_back({d, depth, write, compare, stencil, read, writeMask, front, back});
    return nextHandle++;
}
std::vector<std::vector<uint32_t>> blendCalls;
uint64_t stubCreateBlendState(void *, uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t e, uint32_t f, uint32_t g) {
    blendCalls.push_back({a, b, c, d, e, f, g});
    return nextHandle++;
}
std::vector<uint8_t *> rasterizers;
const void *stubCreateRasterizerState(uint32_t cull, uint32_t fill, bool scissor, bool bias, bool clip) {
    uint8_t *state = static_cast<uint8_t *>(calloc(16, 1));
    state[0] = uint8_t(cull); state[1] = uint8_t(fill); state[3] = scissor; state[4] = bias; state[5] = clip;
    rasterizers.push_back(state);
    return state;
}
std::vector<NSDictionary *> events;
void report(NSDictionary *event) { events.push_back(event); }

// Index `index` with `salt`, and a type in the top bits as BG3 sets them.
uint64_t handleFor(uint32_t index, uint32_t salt) { return (uint64_t(7) << 54) | (uint64_t(salt) << 32) | index; }
char *entryAt(uint32_t index) { return programEntries[index / PerPage] + (index % PerPage) * Layout::ProgramBytes; }
void *stageOf(uint32_t index, size_t offset) { return read<void *>(entryAt(index), offset); }
void setStage(uint32_t index, size_t offset, id<MTLFunction> function) {
    void *value = function ? (void *)CFBridgingRetain(function) : nullptr;
    memcpy(entryAt(index) + offset, &value, sizeof value);
}
BG3MFXProgramID create(const char *base, id<MTLFunction> vertex, id<MTLFunction> fragment) {
    BG3MFXProgramStages stages;
    stages.vertex = vertex; stages.fragment = fragment;
    return BG3MFXCreateProgram(base, stages, nullptr);
}

void testPrograms(id<MTLDevice> metal, id<MTLLibrary> library) {
    id<MTLFunction> baseVS = [library newFunctionWithName:@"baseVS"], baseFS = [library newFunctionWithName:@"baseFS"];
    id<MTLFunction> cloneVS = [library newFunctionWithName:@"cloneVS"], cloneFS = [library newFunctionWithName:@"cloneFS"];
    NSError *error = nil;

    // Before install there is nothing to call.
    check(!create("Base.bshd", nil, cloneFS).valid(), "not installed");

    // The device: Core.metallib at +0x840 gives BG3's Metal device.
    void *core = (__bridge void *)library;
    memcpy(device + Layout::CoreLibrary, &core, sizeof core);
    container(Layout::Programs, programPages, programSaltPages);
    container(Layout::BlendStates, blendPages, blendSaltPages);
    void *devicePointer = device;
    memcpy(reinterpret_cast<char *>(data) + Layout::DataDevice, &devicePointer, sizeof devicePointer);
    makePath = stubMakePath; destroyPath = stubDestroyPath; createShader = stubCreateShader;
    rendererData = &dataPointer; defaultShaderPath = &prefixPointer; reportEvent = report;

    // No device yet: s_Data is still null.
    check(!create("Base.bshd", nil, cloneFS).valid(), "no device");
    check(BG3MFXMetalDevice() == nil, "no Metal device without BG3's");
    dataPointer = data;
    check(BG3MFXMetalDevice() == metal, "BG3's Metal device from Core.metallib");

    // Arguments are checked before BG3 makes a program.
    check(!create("Base.bshd", nil, nil).valid(), "nothing to replace");
    check(!create("", nil, cloneFS).valid(), "no base");
    check(!create("Base.bshd", nil, cloneVS).valid(), "a vertex function as the fragment stage");
    check(!create("Base.bshd", cloneFS, nil).valid(), "a fragment function as the vertex stage");
    check(pathsMade == 0, "no program made for rejected arguments");

    // A program: page 1, slot 1, with both of the base's stages.
    const uint32_t index = PerPage + 1;
    programSalts[1][1] = 0x1234;
    setStage(index, Layout::Vertex, baseVS);
    setStage(index, Layout::Fragment, baseFS);
    nextHandle = handleFor(index, 0x1234);
    const CFIndex baseRetains = CFGetRetainCount((__bridge CFTypeRef)baseFS);
    BG3MFXProgramID program = BG3MFXCreateProgram("DeferredDecal_ExtractNormal.bshd", {nil, cloneFS}, &error);
    check(program.valid() && program.handle == nextHandle, "create returns BG3's handle");
    check(pathName == "DeferredDecal_ExtractNormal.bshd" && pathRoot == Native::EngineShaderRoot && pathPrefix == prefix,
        "path built as LoadEngineShader builds it");
    check(pathsMade == 1 && pathsDestroyed == 1, "path destroyed");
    check(stageOf(index, Layout::Fragment) == (__bridge void *)cloneFS, "fragment replaced");
    check(stageOf(index, Layout::Vertex) == (__bridge void *)baseVS, "vertex kept");
    check(CFGetRetainCount((__bridge CFTypeRef)baseFS) == baseRetains - 1, "replaced function released");
    check(events.size() == 1 && [events[0][@"event"] isEqual:@"programCreated"] && [events[0][@"fragment"] isEqual:@"cloneFS"],
        "creation reported");
    BG3MFXProgramDesc desc;
    check(BG3MFXDescribeProgram(program, &desc) && [desc.path isEqual:@"prefix/DeferredDecal_ExtractNormal.bshd"],
        "a long (heap) path is described");
    check(desc.stages.vertex == baseVS && desc.stages.fragment == cloneFS, "and its stages");

    // Both stages at once.
    setStage(index, Layout::Vertex, baseVS);
    setStage(index, Layout::Fragment, baseFS);
    check(create("Base.bshd", cloneVS, cloneFS).valid(), "both stages");
    check(stageOf(index, Layout::Vertex) == (__bridge void *)cloneVS && stageOf(index, Layout::Fragment) == (__bridge void *)cloneFS,
        "both replaced");
    check(BG3MFXDescribeProgram(program, &desc) && [desc.path isEqual:@"prefix/Base.bshd"], "a short (inline) path is described");

    // BG3's own loads, through the hook.
    Path path;
    const StringView name{"x", 1};
    stubMakePath(&path, 1, "", &name);
    check(createShaderHook(&path) == nextHandle, "the hook returns BG3's handle");
    check(BG3MFXDescribeProgram(program, &desc) && [desc.path isEqual:@"/x"], "and records its path");

    // BG3 couldn't load the file.
    nextHandle = BG3MFXInvalidHandle;
    check(!create("Missing.bshd", nil, cloneFS).valid(), "invalid handle");

    // A handle whose salt isn't its slot's, and a base without the stage:
    // the entry is left as it is.
    setStage(index, Layout::Fragment, baseFS);
    nextHandle = handleFor(index, 0x999);
    check(!create("Base.bshd", nil, cloneFS).valid(), "salt mismatch");
    check(!BG3MFXDescribeProgram(BG3MFXProgramID{nextHandle}, &desc), "a mismatched handle isn't described");
    check(stageOf(index, Layout::Fragment) == (__bridge void *)baseFS, "mismatched entry untouched");
    setStage(index, Layout::Vertex, nil);
    nextHandle = handleFor(index, 0x1234);
    check(!create("Base.bshd", cloneVS, cloneFS).valid(), "base without a vertex stage");
    check(stageOf(index, Layout::Fragment) == (__bridge void *)baseFS, "entry untouched when a stage is missing");

    // Libraries load next to the runtime; a missing one fails.
    check(BG3MFXFunctionLibrary("no-such-library", &error) == nil, "missing library");
}

void testDepthStates() {
    check(!BG3MFXGetOrCreateDepthState({}, nullptr).valid(), "depth: not installed");
    createDepthState = stubCreateDepthState;
    nextHandle = handleFor(0, 1);
    // BG3 makes one: the hook records it and remembers the device.
    const uint64_t equal = createDepthStateHook(device + 8, true, false, MTLCompareFunctionEqual, true, 0x0f, 0x30,
        {1, 0, 2, MTLCompareFunctionGreater}, {1, 0, 2, MTLCompareFunctionGreater});
    check(hookedDevice.load() == device + 8, "the hook keeps BG3's device");
    BG3MFXDepthStateDesc desc;
    check(BG3MFXDescribeDepthState({equal}, &desc) && desc.depthTest && !desc.depthWrite && desc.compare == MTLCompareFunctionEqual &&
          desc.stencil && desc.readMask == 0x0f && desc.writeMask == 0x30 && desc.front.pass == 2 &&
          desc.back.compare == MTLCompareFunctionGreater, "described as BG3 made it");
    check(!BG3MFXDescribeDepthState({handleFor(3, 3)}, &desc), "an unknown state isn't described");
    check(BG3MFXDescribedDepthStates() == 1, "one described");

    // A copy writing with GreaterEqual: made on BG3's device, the rest kept.
    BG3MFXDescribeDepthState({equal}, &desc);
    desc.compare = MTLCompareFunctionGreaterEqual;
    desc.depthWrite = true;
    const BG3MFXDepthStateID writing = BG3MFXGetOrCreateDepthState(desc, nullptr);
    check(writing.valid() && depthCalls.size() == 2, "created");
    const DepthCall &call = depthCalls.back();
    check(call.device == device + 8 && call.write && call.compare == MTLCompareFunctionGreaterEqual && call.read == 0x0f &&
          call.write2 == 0x30 && call.front.pass == 2 && call.back.compare == MTLCompareFunctionGreater, "with the settings given");
    BG3MFXDepthStateDesc created;
    check(BG3MFXDescribeDepthState(writing, &created) && created.depthWrite, "a created state is described");
    check(BG3MFXGetOrCreateDepthState(desc, nullptr).handle == writing.handle && depthCalls.size() == 2, "the same settings, the same state");
    desc.compare = 9;
    check(!BG3MFXGetOrCreateDepthState(desc, nullptr).valid(), "out-of-range compare");
    hookedDevice.store(nullptr);
}

void testBlendStates() {
    BG3MFXBlendStateDesc desc;
    check(BG3MFXDescribeBlendState({}, &desc) && !desc.enabled && desc.writeMask == 15, "the invalid handle is blending off");
    // An entry: slot 2 of page 0.
    blendSalts[0][2] = 0x55;
    const uint8_t bytes[7] = {6, 7, 0, 15, 1, 7, 0};
    memcpy(blendEntries[0] + 2 * Layout::StateBytes, bytes, sizeof bytes);
    check(BG3MFXDescribeBlendState({handleFor(2, 0x55)}, &desc) && desc.enabled && desc.srcRGB == 6 && desc.dstRGB == 7 &&
          desc.writeMask == 15 && desc.dstAlpha == 7, "an entry's bytes");
    check(!BG3MFXDescribeBlendState({handleFor(2, 0x56)}, &desc), "a mismatched salt isn't described");

    check(!BG3MFXGetOrCreateBlendState({true, 1, 0, 0, 15, 1, 0, 0}, nullptr).valid(), "blend: not installed");
    createBlendState = stubCreateBlendState;
    check(!BG3MFXGetOrCreateBlendState({false, 6, 7, 0, 15, 1, 7, 0}, nullptr).valid() && blendCalls.empty(), "disabled is the invalid handle");
    const BG3MFXBlendStateDesc masked{true, 1, 0, 0, 1, 1, 0, 0};
    const BG3MFXBlendStateID red = BG3MFXGetOrCreateBlendState(masked, nullptr);
    check(red.valid() && blendCalls.size() == 1 && blendCalls[0] == std::vector<uint32_t>{1, 0, 0, 1, 1, 0, 0}, "created in BG3's order");
    check(BG3MFXGetOrCreateBlendState(masked, nullptr).handle == red.handle && blendCalls.size() == 1, "the same settings, the same state");
    check(!BG3MFXGetOrCreateBlendState({true, 1, 0, 0, 3, 1, 0, 0}, nullptr).valid(), "a mask BG3 doesn't map");
    check(!BG3MFXGetOrCreateBlendState({true, 11, 0, 0, 15, 1, 0, 0}, nullptr).valid(), "an out-of-range factor");
    check(!BG3MFXGetOrCreateBlendState({true, 1, 0, 5, 15, 1, 0, 0}, nullptr).valid(), "an out-of-range operation");
}

void testRasterizerStates() {
    check(!BG3MFXGetOrCreateRasterizerState({}, nullptr).valid(), "rasterizer: not installed");
    createRasterizerState = stubCreateRasterizerState;
    const BG3MFXRasterizerState none = BG3MFXGetOrCreateRasterizerState({0, 0, false, true, false}, nullptr);
    BG3MFXRasterizerDesc desc;
    check(none.valid() && BG3MFXDescribeRasterizerState(none, &desc) && desc.cull == 0 && desc.depthBias && !desc.depthClip,
        "created and described");
    check(BG3MFXGetOrCreateRasterizerState({0, 0, false, true, false}, nullptr).pointer == none.pointer && rasterizers.size() == 1,
        "the same settings, the same state");
    check(!BG3MFXGetOrCreateRasterizerState({3, 0, false, false, false}, nullptr).valid(), "an out-of-range cull mode");
    check(!BG3MFXDescribeRasterizerState({}, &desc), "null isn't described");
}

void testPipelineRecord() {
    alignas(8) uint8_t record[BG3MFXBuild::PipelineRecord::Bytes] = {};
    check(!BG3MFXPipelineRecord(record).valid(), "another op isn't a pipeline record");
    record[0] = BG3MFXBuild::PipelineRecord::Op;
    BG3MFXPipelineRecord pipeline(record);
    check(pipeline.valid(), "a pipeline record");
    pipeline.setProgram({0x11});
    pipeline.setDepthState({0x22});
    pipeline.setStencilRef(3);
    pipeline.setRasterizer({record});
    pipeline.setBlendState({0x44});
    check(pipeline.program().handle == 0x11 && read<uint64_t>(record, 0x08) == 0x11, "program at +0x08");
    check(pipeline.depthState().handle == 0x22 && read<uint64_t>(record, 0x10) == 0x22, "depth-stencil state at +0x10");
    check(pipeline.stencilRef() == 3 && read<uint32_t>(record, 0x18) == 3, "stencil reference at +0x18");
    check(pipeline.rasterizer().pointer == record && read<void *>(record, 0x20) == record, "rasterizer at +0x20");
    check(pipeline.blendState().handle == 0x44 && read<uint64_t>(record, 0x28) == 0x44, "blend state at +0x28");
}
}

int main() {
    @autoreleasepool {
        id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
        check(metal != nil, "Metal device");
        NSError *error = nil;
        id<MTLLibrary> library = [metal newLibraryWithSource:
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "vertex float4 baseVS(uint v [[vertex_id]]) { return float4(float(v), 0, 0, 1); }\n"
             "fragment float4 baseFS() { return float4(1); }\n"
             "fragment float4 cloneFS() { return float4(0.5); }\n"
             "vertex float4 cloneVS(uint v [[vertex_id]]) { return float4(0, float(v), 0, 1); }\n"
            options:nil error:&error];
        check(library != nil, "test library compiles");
        testPrograms(metal, library);
        testDepthStates();
        testBlendStates();
        testRasterizerStates();
        testPipelineRecord();
        puts("custom-pipeline-bundles: programs (create, describe, paths), depth-stencil, blend and rasterizer "
             "create and describe, and pipeline records passed (synthetic).");
    }
    return 0;
}
