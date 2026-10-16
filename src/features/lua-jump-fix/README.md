# Lua System Call Elimination

Technical name: `lua-system-call-elimination`.

Enabled by default for the supported BG3 build; `BG3MFX_LUA_SYSTEM_CALL_ELIMINATION=0` disables it. Redirects Lua 5.4's protected
call and error jumps to `_setjmp` and `_longjmp`, avoiding signal-mask and
alternate-stack save/restore work in BG3's Lua calls. The patch is guarded by
the supported executable UUID and instruction checks.

Implementation is in
[`LuaJumpFix.mm`](../../../src/features/lua-jump-fix/LuaJumpFix.mm), installed
through [`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm).

On the M5 Pro Lower City CPU sample, the server thread spent 3.5% of samples in
`sigprocmask` and `__sigaltstack` before the change; the protected Lua call
time fell 14% afterward. This is a server-thread CPU reduction, not a measured
frame-rate gain. NPC and combat behavior remained normal during live play; the
runtime regression suite does not exercise this patch. See [performance
analysis](../../../docs/dev/performance.md) and
[current validation](../../../docs/dev/validation/README.md).
