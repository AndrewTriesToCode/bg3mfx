# Custom Render Stages

Technical name: `custom-render-stages`.

Lets other features replace the render stages BG3 creates for each kind of
view, and override methods of particular stage classes. It has no player-visible effect itself: it is enabled by the features
that require it (Duplicate Shadow Fix, Improved Shadows).

## Behavior

`BaseApp::InitFrameStages(view)` passes fixed packs of `rf::AppStageType`
codes to the virtual `BaseApp::InitFrameStages(view, Span)`, which adds one
stage per code (see [views and their stage lists](../../../docs/dev/baseline/README.md#views-and-their-stage-lists)).
A feature registers one list per view kind (Game, Player, Fullscreen,
Offscreen) with `BG3MFXSetViewStages` from its install. A kind without a list
gets BG3's calls unchanged.

A registered list is added on the call that opens the view's sequence (the
First or FullScreen pack), and the view's later packs are skipped, whatever
their number or order. Registration rejects a code the Span overload does not
build, a stage before a stage its construction looks up, and Game or Player
lists without the stages `App::InitFrameStages` inserts BG3's game stages
around.

### Stage method overrides

A feature can replace a method of one stage class with
`BG3MFXOverrideStageMethod(type, method, feature, replacement, &original)`
from its install: `Load`, `Unload`, `Submit` or `StartRecording` (vtable slots
3, 4, 5 and 7). Every stage of that class, in every view, then calls the
replacement, which calls BG3's method through `original`. `Load` returns a bool
(the base `RenderStage::Load` sets the enabled byte and returns 1, and
`StageGroup::AddAppStage` checks it); the others return nothing. One feature
per method; only methods listed in `SupportedBuild.h`
(`CustomRenderStages::StageMethods`) can be overridden:

| Stage type | Class | Methods |
| --- | --- | --- |
| 0x03 | `CascadedShadowMaskStage` | Load, Unload |
| 0x0b | `DeferredBufferStage` | Load, Unload, Submit, StartRecording |

## Implementation

`CustomRenderStages.mm` replaces the Span overload's slot (0x2c8) in App's
vtable, at this feature's activation: after every feature has installed, and
only if a list was registered (or the trace asked for the shim). It checks
both vtable slots and every pack's bytes against `SupportedBuild.h` first.
The vtable page is made writable, the pointer stored, and the page made
read-only again (`BG3MFXPatchPointer`).

Method overrides are written at the same activation, before the stage-list
shim. Every overridden entry is first checked against BG3's method from
`SupportedBuild.h`; if one differs, nothing is written. `original` is set
before the entry is replaced, and if a write fails the entries already written
are put back.

## Improvement

None by itself; the features that register lists measure their own.

## Tests

`tests/features/custom-render-stages/custom_render_stages_smoke.mm`:
passthrough for every kind, one list per opened view whatever packs follow,
unknown spans forwarded, validation, view classification, and the read-only
pointer write; method override validation, one owner per method, the entry
guard, the patch, and BG3's methods handed back, against stand-in read-only
vtables.
