# Character Creation Crash Fix

Technical name: `cluster-buffer-guard`.

Experimental. The `bg3mfx` launcher turns it off unless the player sets
`BG3MFX_CHARACTER_CREATION_CRASH_FIX=1`; the runtime alone enables it when the variable is unset,
and `BG3MFX_CHARACTER_CREATION_CRASH_FIX=0` disables it. BG3 4.1.1
sometimes dispatches its clustered-lighting passes without binding
`ClusterInfoBuffer`. This happens at some render sizes; live, it happened at
1796×1123 (FSR 1.0 Ultra Quality, fullscreen 2336×1460) when entering
character creation. The unbound passes are `ClusteredLighting_0..13`,
`VolumetricFog*` and `ClusterAssignment` on compute, and the character lash
and tearline fragment shaders. The GPU fault that follows wedges the AGX
driver: WindowServer hits its watchdog, and the process cannot be killed until
a reboot. Unmodified BG3 does the same thing, so the bug is BG3's own; bg3mfx
reached it only when the saved MetalFX quality was Ultra Quality.

Live lldb tracing found the cause. Entering character creation creates
`ecl::BasicGameObjectRenderer`, a 300×300 preview renderer with its own scene
graph and `ClusteredAssignmentStage`. The main scene graph's next
`rf::SceneGraph::ConfigureAliasing` clears the main stage's `ClusterInfoBuffer`
entry. The create pass that normally refills the entry in the same call writes
a null buffer instead, one call later. The main stage keeps rendering with that
null entry, so BG3 skips the bind. This lasts until BG3 destroys the preview
renderer on leaving character creation and reconfigures the main graph again.
Why the create pass finds no buffer is not yet pinned down.

[`ClusterBufferGuard.mm`](ClusterBufferGuard.mm) owns one 8 MB zero-filled
stand-in per device. It uses shared storage and is untracked, so encoders
don't serialize on it. [`Trace.mm`](../../integration/renderer/Trace.mm) binds
the stand-in on every new encoder BG3 creates: compute indices 1 and 6, and
fragment index 1. A bind from BG3 replaces it, so the stand-in is only read
where BG3 left the slot empty, and those passes see a frame with no local
lights. Diagnostic builds hook compute buffer binds and record
`clusterBufferGuard` events. Each event names a cluster pass that dispatched
with the stand-in still bound, or with an explicit nil bind.

Live on October 19, at the settings that hung, the first entry into character
creation in one run reproduced the trigger. `ClusterAssignment` and the
volumetric fog passes read the stand-in every frame for about 1 min 47 s
(about 6,400 dispatches). There was no hang and no validation error, and the
user saw normal lighting and fog. An earlier run of many entries never
triggered it, because BG3 bound the buffer itself each time. The cost is two or
three extra binds per encoder; frame time was not measured. See [current
validation](../../../docs/dev/validation/README.md).
