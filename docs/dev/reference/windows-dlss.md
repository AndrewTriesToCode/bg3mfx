# Windows DLSS reference investigation

The licensed Steam download on 2026-10-10 contains `bin/bg3.exe`,
`bin/bg3_dx11.exe`, and `bin/nvngx_dlss.dll`. These files stay in ignored
`build/windows-reference`; they are reference inputs, not distributable tool assets.

The following addresses apply only to this downloaded DirectX 11 executable,
using its preferred image base `0x140000000`. They are not Mac patch addresses.

Disassembly confirms a DLSS parameter helper at `0x1440c21b0`. Its fourth
argument points to a parameter structure with these observed fields:

| Offset | NGX parameter |
| --- | --- |
| 0x00 | Color resource |
| 0x08 | Output resource |
| 0x18 | Depth resource |
| 0x20 | MotionVectors resource |
| 0x28 | Jitter.Offset.X float |
| 0x2c | Jitter.Offset.Y float |
| 0x10 | Sharpness float |
| 0x38 | Reset integer |
| 0x3c | MV.Scale.X float, zero replaced with 1 |
| 0x40 | MV.Scale.Y float, zero replaced with 1 |

A confirmed caller at `0x1440c693e` belongs to the function beginning at
`0x1440c6870`, which copies parameters from its second argument before invoking
the helper. Continue tracing the producer of that parameter block to establish
the game's actual jitter and motion conventions. The helper itself shows SDK
parameter plumbing; it does not establish the values supplied by BG3.

Further caller tracing identifies `0x1440c94fc` in the render-command
dispatcher. It passes the command pointer in R13 as the wrapper's second
argument and the renderer context in R12 as its first. The wrapper copies
0x168 parameter bytes from command + 0x10 and returns a 0x178 command size.
This establishes queued parameter ownership, but the command constructor and
the conditions that set Reset remain untraced. The additional local disassembly
is `build/windows-dlss-producer.txt`; despite that filename, the identified
caller is a dispatcher, not the parameter producer.

Local disassembly and string annotations are in ignored build files
`windows-dlss-parameters.txt`, `windows-dlss-caller.txt`, and
`windows-reference-analysis.json`. llvm-objdump labels unexported functions
relative to the nearest unrelated exported symbol; those labels are not function
identifications.

This provides a reference for comparing Mac TAA and camera data. The active
implementation uses the native macOS MetalFX path; Windows code is not part of
the runtime. The actual Windows parameter producer and reset conditions remain
untraced.
