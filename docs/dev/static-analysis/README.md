# BG3 arm64 executable: high-level analysis

This is a static, high-level map of `build/bg3-arm64`, the ARM64 slice of BG3
4.1.1.7631656. It covers how the app starts and runs, and every game system in
the executable.

The analysis was done with REA using its Hopper provider. A local symbol and
call-graph map built with `nm` and `objdump` served as a cross-check. Nothing
was run, patched or traced. Every claim here comes from static evidence, and
none of it was observed at runtime.

| Document | Contents |
| --- | --- |
| [app-lifecycle.md](app-lifecycle.md) | Process start, the Cocoa shell, engine and game startup, the per-frame path, and the client and server game state machines |
| [systems.md](systems.md) | Every system by namespace: engine core, ECS, gameplay (client, server, shared), UI, scripting, rendering, middleware, and how they call each other |
| [metal.md](metal.md) | Metal API usage: device, layer/HDR, frame pacing and present, commit and upload paths, resources, pipelines, encoders, synchronization, and absent features |

## Identity

| Fact | Value |
| --- | --- |
| SHA-256 (thin slice) | `2e6131d5d8ac23ce63863d914fdd9600ef40e5d8930d0be695d279e47472a2ef` (confirmed by REA `open_binary`) |
| Mach-O UUID | `3B6F6492-114E-3EA2-BC64-DFDDBD361434`, which matches the supported-build guard in AGENTS.md |
| Type | MH_EXECUTE, arm64, PIE, not stripped |
| Entry | `_main` at `0x100b911e8` |
| Signing | `com.larian.bg3`, Developer ID Larian Studios Games Ltd. (VMNEFGE8SY), no hardened runtime, no entitlements |

## What REA (Hopper) reported

| Item | Value |
| --- | --- |
| Segments | `__TEXT` `0x100000000`–`0x1083d0000`, `__DATA_CONST` to `0x10888c000`, `__DATA` to `0x108b30000`, `__LINKEDIT` to `0x10ea74000`, plus Hopper's External Symbols block |
| Procedures | 491,962 in total: about 482.5k carry symbol names and 9,491 are unnamed `sub_` functions Hopper found itself |
| Strings | 55,421 typed string objects |
| `__text` | 125.6 MB (119.7 MiB) at `0x10000dc5c` |

## Cross-check against the local map

The local map in `build/analysis/baseline/game-map/` (ignored by git) has
483,110 named text symbols. Each function is assigned to a system by namespace,
library prefix and source-file (translation unit) layout, and the call graph
comes from the disassembly. REA and the local map were compared in three ways:

- **Exports:** in an earlier REA pass, all 27,099 `__text` exports matched the
  local function index by address and by name.
- **Namespace inventory:** Hopper's procedure counts for the main namespaces
  are 97.9–99.6% of the local symbol counts for the same mangled pattern. For
  example, `N3esv` has 31,973 in Hopper and 32,121 locally, and `N6Noesis` has
  39,773 and 39,934. The local symbols have no duplicate addresses, so the
  small gap is in Hopper's naming, not in aliasing.
- **Call edges:** REA returned callees for 15 key lifecycle functions, listed
  in [rea-callees.tsv](rea-callees.tsv). The local call graph contains 484 of
  Hopper's 489 edges (99.0%), as shown in
  [callee-agreement.tsv](callee-agreement.tsv). The local graph also has 118
  edges that Hopper lacks:
  - 94 lead to exception-cleanup code (destructors, `_Unwind_Resume`,
    `operator delete`), which Hopper leaves out of procedure bodies.
  - 11 of the remaining 24 are in the 30 KB `BaseApp::InitFrameStages`. Hopper
    ends that body early, which drops real calls such as the `ls::CullStage`
    and `ls::RenderContext` constructors.
  - Hopper has 5 edges the local graph lacks. In two of them, a call site
    where the local graph resolves `ls::utf8::CompareNoCase` resolves in Hopper
    to `gui::SortUsersPredicate::Compare`. The cause wasn't established;
    identical-code folding or tail-call handling are the likely candidates.

So the REA call graph is reliable for what it shows, but undercounts cleanup
paths and large functions. Treat it as a lower bound.

## Data files

| File | Contents |
| --- | --- |
| [systems.tsv](systems.tsv) | Code bytes and function count for each system (local map) |
| [ecs-systems.txt](ecs-systems.txt) | All 934 registered ECS systems (from `ls::TypeId<…, ecs::SystemsContext>`) |
| [ecs-components-by-namespace.tsv](ecs-components-by-namespace.tsv) | Counts of the 2,652 ECS components, by namespace and sub-namespace |
| [rea-callees.tsv](rea-callees.tsv) | REA (Hopper) direct callees of the 15 lifecycle functions, with names |
| [callee-agreement.tsv](callee-agreement.tsv) | Per-function comparison of REA and local call edges |
| [metal-selector-callers.tsv](metal-selector-callers.tsv) | 150 Metal/QuartzCore selectors: call sites, calling functions, systems, top callers |
| [metal-import-callers.tsv](metal-import-callers.tsv) | Callers of Metal and CoreVideo C entry points |

The retained REA evidence bundle (34 MB, 34 records) is at
`build/analysis/baseline/rea-hopper/bg3-arm64-hopper-evidence.json`. It is
ignored by git.

## Limitations

- **Static only.** Edges come from direct `bl` and `b` calls. Virtual calls,
  function pointers, `objc_msgSend` targets chosen at runtime, Lua and
  Osiris dispatch are not resolved. `-[AppDelegate launchGame]`, for example,
  reaches the engine through `IApp` virtual calls that neither tool follows.
- **Approximate system boundaries.** Functions without a namespace are
  assigned by the source file they appear to sit in, inferred from
  `__GLOBAL__sub_I_<file>.cpp` markers and code layout. About 0.97 MB of C
  code from bundled libraries remains unattributed.
- **Folded code.** Identical-code folding means one address can serve several
  source functions, so a callee name can be a sibling that happens to share
  the same code (for example `gui::SortUsersPredicate::Compare`).
- **Objective-C classes:** REA's class view refused the 244 MB image because
  it exceeds its 64 MiB default input budget, and that tool has no option to
  raise it. The Objective-C details here come from symbol names instead.
- **Size includes registration code.** Static initializers (18.7 MB, 211k
  functions) and huge `Register*` functions are mostly type registration, not
  behaviour.

## Reproducing

1. Run REA with the Hopper provider.
2. Call `open_binary` on `build/bg3-arm64` with `provider_id: hopper`. The
   first analysis takes a while, so raise `hopper.startup_timeout_ms`.
3. Call `binary_overview`.
4. Run `search_procedures` in summary mode on mangled namespace patterns
   (`N3esv`, `N3ecl`, …).
5. Call `procedure_callees` on the addresses in `rea-callees.tsv`.
6. Export the evidence with `export_evidence_bundle`.
