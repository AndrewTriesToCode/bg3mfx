# Script Fixes

Technical name: `script-fixes`.

Opt-in with `BG3MFX_FEATURE_SCRIPT_FIXES=1` (development launches:
`--feature script-fixes`). The `bg3mfx` launcher does not set it yet. Native:
it hooks two BG3 functions, so it needs the supported build.

## Behavior

Script Fixes corrects bugs in BG3's condition scripts and AI archetypes, and
removes repeated work from three hot condition helpers. Every fix is applied in
memory as BG3 reads the file. Nothing on disk changes, and launching without
bg3mfx gives BG3's original behavior.

A file is patched only if its SHA-256 matches the version BG3 4.1.1.7631656
ships. A file that another mod replaces, or any other version, loads
unchanged. The first such file in a run is logged through `BG3MFXFail`
(subsystem `com.bg3mfx`) and shows no dialog.

### Bug fixes

These change gameplay.

- **NPCs can use weapon actions.** In `CommonConditions.khn`,
  `CanUseWeaponActions` returned
  `not Tagged('AI_BLOCKWEAPONACTIONS') | Player()`. Lua's `not` cannot be
  overloaded, so it returns `false` for any condition result, and the helper
  reduced to `Player()`. No NPC could use the 20 weapon actions that require
  it, such as Topple and Lacerate. The fix uses `~`, the condition negation:
  NPCs now use them unless tagged `AI_BLOCKWEAPONACTIONS`. Expect enemies to
  fight harder.
- **Reapplying Heat Metal makes its saving throw.** In
  `CommonConditions.khn`, `HeatMetalReapplyCheck` checked both hands against
  the undefined global `weaponEntity`. So it looked for HEAT_METAL on the
  wielder, but the status is on the weapon, and the Constitution save never
  ran. It now checks the main-hand and off-hand weapons, so a failed save
  disarms the target (`SpellSuccess` DISARM).
- **Omen chances follow their DC.** In `CommonConditions.khn`,
  `RollDieAgainstPercent(diceType, DC)` ignored its DC and succeeded on an
  even roll, which is 50% for every die. It now succeeds when the roll is at
  or under the DC:

  | Omen | Before | After |
  | --- | --- | --- |
  | OMEN_ACID (d6, 1) | 1 in 2 | 1 in 6 |
  | OMEN_COLD (d10, 2) | 1 in 2 | 1 in 5 |
  | OMEN_FIRE (d4, 1) | 1 in 2 | 1 in 4 |
  | OMEN_LIGHTNING (d6, 2) | 1 in 2 | 1 in 3 |
  | OMEN_THUNDER (d4, 2) | 1 in 2 | 1 in 2 |

  The two direct `RollDieAgainstPercent(DiceType.d4,2)` rolls (in
  `Interrupt.txt` and `Status_BOOST.txt`) stay at 1 in 2.
- **Greater Invisibility checks the event.** `GreaterInvisibilityCheck_InvisSpellOrRoll`
  appears in `CommonConditionsDev.khn` and in Honour mode's
  `CommonConditions.khn`. It used
  `IsStatusEvent(StatusEvent.OnSpellCast) and HasSpellFlag(SpellFlags.Invisible)`.
  Lua's `and` returns its second operand, so the event test was dropped, and
  any event carrying an invisibility spell skipped the Stealth check. Now only
  casting one does (`&`).
- **Animate Dead zombies check where they stand.** `generateConditionString.khn`
  turns stats conditions into Lua: it rewrites ` and ` and ` or ` into the
  condition operators `&` and `|`, but not a keyword followed directly by
  `(`.
  - **Affected spells:** `Target_AnimateDead_Zombie_4` and
    `Target_MAG_Myrkulites_AnimateDead_Zombie` write `CanStand('…') and((…`.
    That stayed Lua's `and`, which skipped their `CanStand` check, so a zombie
    could be raised where it cannot stand. The base zombie spell has the space
    and is unaffected.
  - **Fix:** the preprocessor now also rewrites ` and(`, `)and(`, ` or(` and
    `)or(`.
  - **Scope:** in the shipped stats, this changes only those two conditions.
- **Gortash prefers buffing himself.** In `act3_WYR_Gortash_ranged.txt`, a
  line commented "buffing self - Gort is really interested" set
  `MULTIPLIER_BOOST_ALLY_POS 2.0`, and the next line set it again to 1.0, so
  the 2.0 was lost. The line now sets `MULTIPLIER_BOOST_SELF_POS 2.0`.
- **Mind flayers have good hit/miss reasoning, not inverted reasoning.** In
  `mindflayer.txt`, under the comment "Good hit/miss reasoning", the line set
  `MODIFIER_HIT_CHANCE_STUPIDITY` to an absolute -0.15. Every other archetype
  lowers it relatively from the 1.0 base, with
  `- MODIFIER_HIT_CHANCE_STUPIDITY 0.15`. It is now a relative -0.15, giving
  0.55 after `ranged` and `ranged_smart`.

### Speed

These keep every result identical and remove repeated engine calls from
helpers that BG3 evaluates often.

- **`AttackedWithPassiveSourceWeapon`** is used by 75 passives. It called
  `GetAttackWeapon()` six times per evaluation and now calls it once: five
  fewer engine calls each time.
- **`IsCurvingShot`** or-ed 56 `SpellId` results, each `|` building a new
  condition result through a metamethod, and used only `.Result`. The same
  chain now ORs plain integers and stops calling `SpellId` after the first
  match. A miss saves 55 result objects; a hit also saves the remaining
  `SpellId` calls.
- **`ArcaneAcuityGlovesCondition`** called `GetActiveWeapon()` nine times and
  `GetActiveWeapon(context.Source, false)` eight times. It now calls each once:
  up to 15 fewer engine calls per evaluation.

These are estimates from call counts. The gains are on BG3's server thread
during combat and have not been measured in frames. Other rewrites would have
changed results:

- **`AnyEntityIsItem` (153 interrupts), `IsAbleToReact` (134) and
  `StatusDoesNotInvokeOnStatusApply` (65 `StatusId` calls):** their callers
  get the whole condition result.
- **Short-circuiting changes that result.** BG3's `|` (`thoth::shared::operator|`)
  does more than OR the two Results. It merges both sides' error lists when
  their Results agree, unions two sets, combines Chance as 1 − (1 − a)(1 − b),
  and ORs a flag. Skipping an operand changes tooltips and roll chances.

### Not bugs

Two other suspected problems turned out to change nothing.
`LoadModifiersFromDisk` strips all blanks before parsing, so
`+MULTIPLIER_KILL_ENEMY` in `mindflayer.txt` already reads as
`+ MULTIPLIER_KILL_ENEMY`. The repeated keys in `orthon_melee.txt`,
`orthon_ranged.txt` and `ogre_melee.txt` are absolute settings, and the last
one, which the comments agree with, already wins.

## Implementation

[`ScriptFixes.h`](../../../src/features/script-fixes/ScriptFixes.h) holds the
table and the patching logic:

- **Table:** each file's path suffix and the SHA-256 of the shipped file, plus
  edits that each replace one exact span. The table carries only those spans
  and the new text, never a game file.
- **Hooks:** [`ScriptFixes.mm`](../../../src/features/script-fixes/ScriptFixes.mm)
  hooks two function entries (`SupportedBuild.h`, `ScriptFixes`; island
  `Islands::ScriptFixes`).

The two hooks handle the two kinds of file:

- **Scripts:** Lua 5.4's `lua_load` compiles every Thoth helper, Anubis
  behaviour tree and condition string. A script's chunk name is `@` and its
  path (`thoth::shared::Machine::LoadScript`, `khonsu::Machine::Load`). A
  chunk whose path ends with a table entry is read whole and hashed. A
  patched copy goes to the original `lua_load`, so edits may change length.
- **AI archetypes:** `(anonymous)::LoadModifiersFromDisk` reads them line by
  line from an `ls::FileReader`. Right after the reader's constructor
  (`FileReader(Path const&, EType, EnumFlags)`), a table file is hashed and
  patched in place; these edits keep the file's length.
  - **Shared pak data:** a packaged file's data can be the FileManager's own
    in-memory copy, shared by every reader. A copy that is already patched is
    recognized by reversing the edits and is left alone.
  - **Read-only pages:** they are made copy-on-write for the write and then
    returned to their protection.

Cost for every other file is one path-suffix comparison per chunk compiled or
file opened.

## Validation

- **`make test`:** `script-fixes-smoke` runs synthetic checks:
  - path matching
  - unrelated chunks keeping BG3's reader
  - unknown scripts and archetypes loading unchanged and reported
  - data edits keeping their length

  When the files have been extracted to `build/evidence/game-scripts/`
  (`SCRIPTS_DIR`), it also checks each table entry against the real file. It
  checks the hash, that every edit matches exactly once, and that scripts are
  patched through the `lua_load` path, read in pieces. For archetypes, it
  checks that they are patched in place once, left alone when already
  patched, and reported when unwritable.
- **Not run in Lua:** no Lua interpreter was available, so the patched
  scripts have not been compiled outside the game.
- **Not yet tested live:** it needs a check that NPCs use weapon actions and
  that no `script-fixes` failure is logged.
