#pragma once
// Script fixes: corrections to BG3's scripts and AI data, applied in memory as
// the game reads them. A file named here is read whole and patched only if
// its SHA-256 is the one BG3 4.1.1.7631656 ships: a mod's replacement, or any
// other version, loads as it is. The edits are the whole of bg3mfx's change;
// no game file is included.
//
// Two kinds of file, by how BG3 reads them:
// - Script: Thoth helpers and the condition preprocessor, which BG3's Khonsu
//   machine compiles with Lua 5.4's lua_load. The chunk name is "@" and the
//   path; the hook hands lua_load a patched copy, so edits may change length.
// - Data: AI archetypes, which the archetype loader reads line by line from an
//   ls::FileReader's buffer. The hook patches that buffer in place right after
//   the reader is constructed, so each edit keeps the file's length.
//
// Header-only so the feature test exercises the same code as the runtime.
#include <CommonCrypto/CommonDigest.h>
#include <cstddef>
#include <cstring>
#include <string>
#include <string_view>

namespace BG3MFXScriptFixes {

// Replaces `from`, which must occur exactly once, with `to`.
struct Edit { std::string_view from, to; };
enum class Kind { Script, Data };
struct File {
    Kind kind;
    std::string_view path;    // the end of the path, after a '/'
    std::string_view sha256;  // lower-case hex of the shipped file
    const Edit *edits;
    size_t count;
};

// Scripts/thoth/helpers/CommonConditions.khn (Shared).
inline constexpr Edit commonConditions[] = {
    // Bug: CanUseWeaponActions. Lua's `not` is not overloadable, so `not
    // Tagged(...)` is false for any ConditionResult and the helper reduced to
    // Player(): no NPC could use the 20 weapon actions that require it,
    // tagged AI_BLOCKWEAPONACTIONS or not. `~` is the condition negation.
    {"return not Tagged('AI_BLOCKWEAPONACTIONS') | Player()",
     "return ~Tagged('AI_BLOCKWEAPONACTIONS') | Player()"},
    // Bug: HeatMetalReapplyCheck. Both hands read the undefined global
    // `weaponEntity`, so HasStatus checked the wielder, not the heated
    // weapon, and Target_HeatMetal_Reapply never made its saving throw.
    {"mainWeapon = HasStatus('HEAT_METAL', weaponEntity,",
     "mainWeapon = HasStatus('HEAT_METAL', mainWeaponEntity,"},
    {"offWeapon = HasStatus('HEAT_METAL', weaponEntity,",
     "offWeapon = HasStatus('HEAT_METAL', offWeaponEntity,"},
    // Bug: RollDieAgainstPercent ignored its DC (`roll % 2 == 0`), so every
    // caller succeeded half the time. Its callers pass a die and the highest
    // roll that succeeds: d4 with 2 (unchanged, 1 in 2) and the Omens, d6 with
    // 1, d10 with 2, d4 with 1, d6 with 2 and d4 with 2.
    {"if roll % 2 == 0 then", "if roll <= DC then"},
    // Speed: AttackedWithPassiveSourceWeapon (75 passives) asked for the
    // attack weapon six times; it now asks once. The getter reads the
    // condition's context, so every call returned the same entity.
    {"function AttackedWithPassiveSourceWeapon()\r\n",
     "function AttackedWithPassiveSourceWeapon()\r\n"
     "    local attackWeapon = GetAttackWeapon()\r\n"
     "    local function GetAttackWeapon() return attackWeapon end\r\n"},
    // Speed: IsCurvingShot or-ed 56 SpellId results, each `|` building a new
    // ConditionResult, and kept only `.Result`. The same chain now ORs
    // integers and stops asking SpellId once one matched.
    {"function IsCurvingShot()\r\n",
     "function IsCurvingShot()\r\n"
     "    local spellId, matched = SpellId, false\r\n"
     "    local function SpellId(id)\r\n"
     "        matched = matched or spellId(id).Result\r\n"
     "        return matched and 1 or 0\r\n"
     "    end\r\n"},
    {"return ConditionResult(res.Result, {ConditionError(\"HasNotMetalWeapon\")}",
     "return ConditionResult(res ~= 0, {ConditionError(\"HasNotMetalWeapon\")}"},
    // Speed: ArcaneAcuityGlovesCondition asked for the main-hand weapon nine
    // times and the off-hand weapon eight times; it now asks once for each.
    {"function ArcaneAcuityGlovesCondition()\r\n",
     "function ArcaneAcuityGlovesCondition()\r\n"
     "    local getActiveWeapon, mainHandWeapon, offHandWeapon = GetActiveWeapon, nil, nil\r\n"
     "    local function GetActiveWeapon(entity, mainHand)\r\n"
     "        if entity == nil and mainHand == nil then\r\n"
     "            if mainHandWeapon == nil then mainHandWeapon = getActiveWeapon() end\r\n"
     "            return mainHandWeapon\r\n"
     "        elseif mainHand == false and entity == context.Source then\r\n"
     "            if offHandWeapon == nil then offHandWeapon = getActiveWeapon(entity, false) end\r\n"
     "            return offHandWeapon\r\n"
     "        end\r\n"
     "        return getActiveWeapon(entity, mainHand)\r\n"
     "    end\r\n"},
};

// Bug: GreaterInvisibilityCheck_InvisSpellOrRoll, in CommonConditionsDev.khn
// and in Honour mode's CommonConditions.khn. Lua's `and` returns its second
// operand for any ConditionResult, so the status-event test was dropped and
// any event carrying an invisibility spell skipped the Stealth check.
inline constexpr Edit greaterInvisibility[] = {
    {"IsStatusEvent(StatusEvent.OnSpellCast) and HasSpellFlag(SpellFlags.Invisible)",
     "IsStatusEvent(StatusEvent.OnSpellCast) & HasSpellFlag(SpellFlags.Invisible)"},
};

// Bug: generateConditionString turns stats conditions into Lua, rewriting
// " and " and " or " into the condition operators. A keyword followed by "("
// stayed Lua's `and`/`or`, which return an operand instead of combining: the
// zombie Animate Dead variants (Target_AnimateDead_Zombie_4,
// Target_MAG_Myrkulites_AnimateDead_Zombie) write `CanStand(...) and((`, so
// their CanStand check was skipped. They are the only shipped conditions this
// changes.
inline constexpr Edit conditionPreprocessor[] = {
    {"    result = string.gsub(result, \"%)or \", \")|\")\r\n",
     "    result = string.gsub(result, \"%)or \", \")|\")\r\n"
     "    result = string.gsub(result, \" and%(\", \"&(\")\r\n"
     "    result = string.gsub(result, \"%)and%(\", \")&(\")\r\n"
     "    result = string.gsub(result, \" or%(\", \"|(\")\r\n"
     "    result = string.gsub(result, \"%)or%(\", \")|(\")\r\n"},
};

// Bug: Gortash's ranged archetype. Its comment says "buffing self", but the
// line sets MULTIPLIER_BOOST_ALLY_POS, which the next line sets again to 1.0:
// the 2.0 was lost.
inline constexpr Edit gortashRanged[] = {
    {"MULTIPLIER_BOOST_ALLY_POS\t\t \t\t\t\t2.0", "MULTIPLIER_BOOST_SELF_POS\t\t \t\t\t\t2.0"},
};
// Bug: the mind flayer archetype set MODIFIER_HIT_CHANCE_STUPIDITY to -0.15
// ("Good hit/miss reasoning"); every other archetype lowers it relatively
// (`- MODIFIER_HIT_CHANCE_STUPIDITY 0.15`) from the 1.0 base. The loader
// strips blanks, so moving the sign before the name keeps the length.
inline constexpr Edit mindFlayer[] = {
    {"MODIFIER_HIT_CHANCE_STUPIDITY \t\t\t\t\t\t\t-0.15", "-MODIFIER_HIT_CHANCE_STUPIDITY\t\t\t\t\t\t\t 0.15"},
};

template <size_t N> constexpr size_t count(const Edit (&)[N]) { return N; }
inline constexpr File files[] = {
    {Kind::Script, "thoth/helpers/CommonConditions.khn",
     "d57caf2681482156fa20452bff493cbe5d4609ff5ea9c7eeb81f803ea08642b7", commonConditions, count(commonConditions)},
    {Kind::Script, "thoth/helpers/CommonConditionsDev.khn",
     "1821d84b2b6d91dca9747a7870fd1ad4e0ee4f607c7284901375afb976d75eab", greaterInvisibility, count(greaterInvisibility)},
    // Mods/Honour/Scripts/thoth/helpers/CommonConditions.khn.
    {Kind::Script, "thoth/helpers/CommonConditions.khn",
     "c6e3d6a1297e5a07a563f5ea222b5144a190fbfb07341bb5958c0fb456c906b9", greaterInvisibility, count(greaterInvisibility)},
    {Kind::Script, "thoth/generateConditionString.khn",
     "4c18813c60c536859270329c37305a9b03e914fe76fcd37bc1fdb69e3ae400d1", conditionPreprocessor, count(conditionPreprocessor)},
    {Kind::Data, "AI/Archetypes/act3_WYR_Gortash_ranged.txt",
     "3a66e7d6d54e067b5e27d0888f8f27d17f7a333201cde7d1dd0962e8e6efce98", gortashRanged, count(gortashRanged)},
    {Kind::Data, "AI/Archetypes/mindflayer.txt",
     "fc71660a87498356e64650a4e4aa362d860f78fbddbf276704f26a654166d8ed", mindFlayer, count(mindFlayer)},
};

// The table path `path` ends with (after a '/' or '\'), or empty. Cheap: every
// condition BG3 compiles and every file it reads passes here.
inline std::string_view Candidate(Kind kind, std::string_view path) {
    for (const File &file : files) {
        if (file.kind != kind || path.size() < file.path.size()) continue;
        std::string_view tail = path.substr(path.size() - file.path.size());
        if (tail != file.path) continue;
        if (path.size() == file.path.size()) return file.path;
        char before = path[path.size() - file.path.size() - 1];
        if (before == '/' || before == '\\') return file.path;
    }
    return {};
}
// A lua_load chunk name: "@" and the path.
inline std::string_view ScriptCandidate(const char *chunk) {
    if (!chunk || chunk[0] != '@') return {};
    return Candidate(Kind::Script, chunk + 1);
}

inline std::string Sha256(std::string_view bytes) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest);
    static const char hex[] = "0123456789abcdef";
    std::string out(2 * sizeof digest, '0');
    for (size_t i = 0; i < sizeof digest; ++i) {
        out[2 * i] = hex[digest[i] >> 4];
        out[2 * i + 1] = hex[digest[i] & 15];
    }
    return out;
}

// Replaces each `from` with `to` (`reverse` swaps them), each matching once.
inline bool ApplyEdits(const File &file, std::string &text, bool reverse = false) {
    for (size_t i = 0; i < file.count; ++i) {
        std::string_view from = reverse ? file.edits[i].to : file.edits[i].from;
        std::string_view to = reverse ? file.edits[i].from : file.edits[i].to;
        size_t at = text.find(from);
        if (at == std::string::npos || text.find(from, at + 1) != std::string::npos) return false;
        text.replace(at, from.size(), to);
    }
    return true;
}

// Patched: `out` holds the fixed file. AlreadyPatched: `source` is the fixed
// file (BG3 hands every reader the same in-memory pak data, patched on its
// first read). Unknown: no shipped file has its hash. EditFailed (a table
// error, which the test rules out): `out` is not to be used. NotWritable: a
// Data file's memory could not be written.
enum class Result { Patched, AlreadyPatched, Unknown, EditFailed, NotWritable };
inline Result Apply(Kind kind, std::string_view path, std::string_view source, std::string &out) {
    const std::string hash = Sha256(source);
    bool named = false;
    for (const File &file : files) {
        if (file.kind != kind || file.path != path) continue;
        named = true;
        if (file.sha256 != hash) continue;
        out.assign(source);
        return ApplyEdits(file, out) ? Result::Patched : Result::EditFailed;
    }
    if (!named) return Result::Unknown;
    for (const File &file : files) {
        if (file.kind != kind || file.path != path) continue;
        std::string original(source);
        if (ApplyEdits(file, original, true) && Sha256(original) == file.sha256) return Result::AlreadyPatched;
    }
    return Result::Unknown;
}

// lua_Reader and lua_load.
using Reader = const char *(*)(void *L, void *data, size_t *size);
using Load = int (*)(void *L, Reader reader, void *data, const char *chunk, const char *mode);

struct Buffer { const char *bytes; size_t size; bool read; };
inline const char *ReadBuffer(void *, void *data, size_t *size) {
    auto *buffer = static_cast<Buffer *>(data);
    if (buffer->read) { *size = 0; return nullptr; }
    buffer->read = true;
    *size = buffer->size;
    return buffer->bytes;
}

// lua_load through `original`, patching a Script file named in `files`.
// `skipped` (path, Result) is called when a named file loads unpatched.
template <typename Skipped>
int LoadFixed(Load original, void *L, Reader reader, void *data, const char *chunk, const char *mode,
    Skipped skipped) {
    std::string_view path = ScriptCandidate(chunk);
    if (path.empty()) return original(L, reader, data, chunk, mode);
    std::string source;
    size_t size = 0;
    while (const char *piece = reader(L, data, &size)) {
        if (!size) break;
        source.append(piece, size);
    }
    std::string patched;
    Result result = Apply(Kind::Script, path, source, patched);
    if (result != Result::Patched && result != Result::AlreadyPatched) skipped(std::string_view(chunk + 1), result);
    const std::string &code = result == Result::Patched ? patched : source;
    Buffer buffer{code.data(), code.size(), false};
    return original(L, ReadBuffer, &buffer, chunk, mode);
}

// Patches a Data file's bytes in place. `write(bytes, patched, size)` copies
// the patched file over them (false: it could not, and left them). `skipped`
// as for LoadFixed.
template <typename Write, typename Skipped>
void PatchData(std::string_view path, char *bytes, size_t size, Write write, Skipped skipped) {
    std::string_view name = Candidate(Kind::Data, path);
    if (name.empty() || !bytes) return;
    std::string patched;
    Result result = Apply(Kind::Data, name, std::string_view(bytes, size), patched);
    if (result == Result::AlreadyPatched) return;
    if (result == Result::Patched && patched.size() != size) result = Result::EditFailed;
    if (result != Result::Patched) { skipped(path, result); return; }
    if (!write(bytes, patched.data(), size)) skipped(path, Result::NotWritable);
}

}  // namespace BG3MFXScriptFixes
