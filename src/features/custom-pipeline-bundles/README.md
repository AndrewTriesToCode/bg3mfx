# Custom Pipeline Bundles

Technical name: `custom-pipeline-bundles`.

Lets other features give BG3 pipelines their own pieces: programs that run
bg3mfx's stage functions, and depth-stencil, blend and rasterizer states. It
has no player-visible effect itself; it is enabled by the features that
require it (improved-shadows). It replaces custom-shaders.

## Behavior

A BG3 pipeline record (op 0x2b) carries a bundle of five pieces, which
[`PipelineRecord.h`](PipelineRecord.h) reads and writes on a raw record
(`BG3MFXPipelineRecord`):

| Piece | Record | BG3 keeps it | Swapping it builds a pipeline? |
| --- | --- | --- | --- |
| Program (BG3's `ShaderID`: one `.bshd`'s stage functions and bindings) | +0x08 | GPU device's program container | Yes, once per new combination |
| Depth-stencil state | +0x10 | Device container; Metal state at entry +0x00 | No |
| Stencil reference | +0x18 (u32) | In the record | No |
| Rasterizer state | +0x20 | A 16-byte struct, by pointer | No (encoder state; not checked in BG3's hash) |
| Blend state | +0x28 | Device container; settings in the entry | Yes; the invalid handle is blending off |

For each kind of piece, [`CustomPipelineBundles.h`](CustomPipelineBundles.h)
has `BG3MFXDescribe…`, which says what BG3 made a piece with, and a call
that has BG3 make a new one through the same function BG3 uses, so the
result is an ordinary BG3 handle a record can carry. A feature describes a
piece, changes what it needs and makes the result; everything it doesn't
change stays as the original. States are cached by their settings, so their
calls are `BG3MFXGetOrCreate…`: the first call with some settings has BG3
make the state, and later ones return it. Programs aren't cached
(`BG3MFXCreateProgram` makes a new one each call). Nothing made is freed:
BG3's pipeline cache keeps pipelines built from it.

- **Programs.** `BG3MFXCreateProgram(base, stages)` has BG3 load a new
  program from a base `.bshd` and puts the given vertex and/or fragment
  function in place of the base's. Replacement functions come from
  `BG3MFXFunctionLibrary(name)`, which loads `<name>.metallib` from beside the
  runtime on BG3's Metal device (`BG3MFXMetalDevice`). The program keeps the
  base's binding information, so a replacement must use the same bindings or
  fewer. The base program, which BG3 shares by path, is unchanged.
  `BG3MFXDescribeProgram` gives a program's `.bshd` path (BG3's program cache
  key) and its stage functions; built-in programs, which BG3 makes from bytes
  in its executable, have no path.
- **Depth-stencil states** record depth test and write, compare function,
  stencil, masks and per-face stencil operations.
- **Blend states** hold BG3's factors, operations and one write mask for
  every color attachment. BG3 maps only single channels, RGB, alpha, all and
  none. Blending is off only for the invalid handle, so masking channels
  without blending needs a state with factors one and zero.
- **Rasterizer states** hold cull, fill, scissor, depth bias (BG3's fixed
  values) and depth clip.

These calls work from any thread once BG3's GPU device exists (the
rasterizer needs no device).

## Implementation

[`CustomPipelineBundles.mm`](CustomPipelineBundles.mm). Addresses and offsets
are in `SupportedBuild.h` (`CustomPipelineBundles`, `PipelineRecord`). The
creating functions are internal to BG3, so the compiler dropped parameters
they don't use; the argument lists there are the ones the code takes.

- **Programs.** It builds an `ls::Path` the way `RenderStage::LoadEngineShader`
  does and calls `rf::DataLoader::CreateShader` directly, below
  `ResourceManager`'s program cache. So no other caller gets the program, and
  `ResourceManager::RemoveShader`, which destroys the shared program it is
  given, never sees it. It resolves the handle to the program's entry (page
  and slot from the index, then a salt check) and swaps the functions at
  +0x18 (vertex) and +0x20 (fragment); the entry owns its functions at +1. An
  entry hook on `DataLoader::CreateShader` records each program's path, from
  the `ls::Path` short string.
- **Depth-stencil states.** `GPUDevice::CreateDepthState` keeps only the Metal
  state, so an entry hook records each state's arguments, and the device it was
  called on, as BG3 makes it. Creating calls the original past the hook.
- **Blend states** are read from their entry's seven bytes and made with
  `GPUDevice::CreateBlendState`.
- **Rasterizer states** are read from their struct and made with
  `GPUDevice::CreateRasterizerState`, which takes no device.

The two entry hooks move each function's first instruction to a 24-byte
island at header padding +0xd08 and +0xd20, at install, before BG3's renderer
makes its own pieces. The diagnostic runtime reports
`customPipelineBundlesInstalled`, `programCreated`, `depthStateCreated` and
`blendStateCreated`.

Whether BG3 releases a program's functions when it destroys the program
(`GPUDevice::DestroyShader` defers the work) is not yet read; the ownership
convention is the same either way.

## Improvement

None by itself; the features that use it measure their own.

## Tests

[`custom_pipeline_bundles_smoke.mm`](../../../tests/features/custom-pipeline-bundles/custom_pipeline_bundles_smoke.mm)
(synthetic), against a stand-in device and containers with real Metal
functions:

- **Programs:** argument and stage-type checks; the path passed to BG3 and the
  path recorded, inline and on the heap; the hook; salt mismatch; stage
  replacement and release; a base without the stage; a missing library.
- **Depth-stencil states:** recorded by the hook, created on BG3's device with
  the settings given, cached, out-of-range compare.
- **Blend states:** the invalid handle as blending off, entry bytes, argument
  order, cached, unsupported masks and out-of-range values.
- **Rasterizer states:** created, described and cached.
- **Pipeline records:** each field's offset.
