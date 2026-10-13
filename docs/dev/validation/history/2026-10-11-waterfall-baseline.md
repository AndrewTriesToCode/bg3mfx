# Waterfall baseline reproduction — October 11, 2026

The user manually navigated pristine BG3 PID 2060 to the waterfall area.
`build/game-waterfall-pristine.log` then repeatedly reported both original
waterfall foam vertex shader faults:

- STI_DEP: WorldOffset INF/NAN, UID
  CB318BBAAFEE71D51F9C8B873F25B37049113E6A5EFAFA10A6E3FA0B99B5CEE7.
- STI_VEL: ProjectedPosition_prev INF/NAN, UID
  C75A04CE086C5932B975BC6CC69DF1C3706A073D83F1D7C97B015239F7343540.

This run has no injected BG3MFX library (confirmed with lsof), uses native FSR
Quality and TAA, windowed 1280×800, Metal HUD, launcher bypass `-NoLauncher 1`.
Shader validation is report-only; API validation is off. The three previously
proven camera/room shader exclusions remain; neither waterfall shader is
excluded. This proves these particular invalid outputs occur in the original
Mac game, independently of MetalFX. It does not prove all reported gameplay
crashes have the same cause or establish a clean overall validation pass.

Earlier diagnostic PID 716 reproduced both faults with native FSR selected.
Diagnostic buffer readbacks in ignored `build/waterfall-capture/` contain an
840-index, 168-vertex mesh with 16 referenced vertices whose normalized vertex
color green is zero. The original Mac shader divides by this channel in its
foam displacement calculation. This is a strong cause candidate; no shader
repair or visual equivalence has been verified. Local extracted shaders and
captures must not be distributed. `tools/analyze_waterfall_capture.py` checks
layout/index coverage and reports the zero-green vertices without changing data.

The downloaded Windows executables do not contain the waterfall material shader
bodies; the corresponding Windows material assets have not yet been compared.
Do not claim a Windows-derived fix.

At this observation the game remains running under the user's manual control.
Do not move the camera or quit during that handoff. Restore Off/TAA, sharpening
On, HUD On, windowed 1280×800 and quit normally once testing ends.
