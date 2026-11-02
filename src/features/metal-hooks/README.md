# Metal Hooks

Technical name: `metal-hooks`.

The Metal interception layer the other renderer features build on. It has no
player-visible effect itself and no flag: it is wanted in every process, also
outside BG3 so the hook regressions can run it.

## Behavior

At activation, after every feature has installed, it swizzles the Metal
device, command queue, command buffer and encoder methods BG3 uses, keeps the
originals, and tracks each encoder's bound pipeline, textures and
depth-stencil state. Features that require it register from their install
([`MetalHooks.h`](MetalHooks.h)); the registrations are read without locks
afterwards:

- new-encoder and render-pass observers (up to four each);
- one draw replacement, which takes the non-indexed draws of the render
  pipelines it claims (metalfx's renderer);
- redundant bind filtering ([`BindFilter.h`](BindFilter.h)), metal-hooks' own
  rules inline in its bind hooks, switched on by render-thread-optimizations;
- in the diagnostic runtime, compute bind and dispatch observers.

metalfx-renderer extends it through the private
[`MetalHooksInternal.h`](MetalHooksInternal.h). metal-hooks includes no
feature's header.

## Implementation

[`MetalHooks.mm`](MetalHooks.mm) holds the hooks and, in the diagnostic
runtime, the render-call trace, constant and redundant-bind probes and the
waterfall capture.

## Improvement

None by itself. An observer point with nothing registered costs one count
check.

## Tests

[`bind_filter_smoke.mm`](../../../tests/features/metal-hooks/bind_filter_smoke.mm)
covers the bind filter's rules. The hook regressions (`spatial-hook-smoke`,
`temporal-hook-smoke`, `frame-generation-hook-smoke`,
`new-character-crash-fix-smoke`) run metal-hooks through both runtimes on
synthetic offscreen draws.
