# Native integration support

`SupportedBuild.h` owns the supported Steam build identity, ARM64 virtual
addresses, native object layouts, and branch-island reservations. The C/Objective-C
launcher consumes its string macros, runtime C++ code uses feature namespaces,
and `tools/launch/bg3mfx.py` reads the same version and SHA definitions.

All addresses are unslid; callers add the validated image slide. The runtime UUID
check remains mandatory before feature installation. Each native installer also
checks its expected instructions and zero island bytes before modifying memory.
`CodePatch.*` supplies branch-range validation and all-or-nothing writable-page
preparation; these mechanisms do not identify or authorize other BG3 versions.

Changing support requires revalidating the identity, addresses, layouts, instruction
guards, and independent fixtures together. Compile-time island checks and
`tests/common/supported_build_smoke.cpp` reject overlap, misalignment, empty ranges,
and bounds/overflow errors. See [architecture](../../../docs/dev/architecture.md)
and [development](../../../docs/dev/development.md). No performance gain is claimed
for this maintenance structure.
