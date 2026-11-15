// script-fixes: path matching, pass-through of unknown and unrelated files,
// in-place data patching (same length, once), and, when the game's files
// have been extracted locally (argv[1], ignored build/ path), that every table
// entry's hash and edits match them.
#include "features/script-fixes/ScriptFixes.h"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <vector>

namespace Fixes = BG3MFXScriptFixes;
using Fixes::Kind;

static int failures = 0;
#define CHECK(condition, ...) do { if (!(condition)) { ++failures; std::fprintf(stderr, "FAIL: " __VA_ARGS__); std::fputc('\n', stderr); } } while (0)

namespace {
// A reader that yields its pieces one at a time, like a streamed file.
struct Pieces { std::vector<std::string> parts; size_t next = 0; };
const char *readPieces(void *, void *data, size_t *size) {
    auto *pieces = static_cast<Pieces *>(data);
    if (pieces->next == pieces->parts.size()) { *size = 0; return nullptr; }
    const std::string &part = pieces->parts[pieces->next++];
    *size = part.size();
    return part.data();
}

// Stands in for lua_load: records the reader it was given and what it read.
struct Loaded { Fixes::Reader reader = nullptr; void *data = nullptr; std::string bytes; const char *chunk = nullptr; };
Loaded loaded;
int fakeLoad(void *L, Fixes::Reader reader, void *data, const char *chunk, const char *) {
    loaded = Loaded{reader, data, {}, chunk};
    size_t size = 0;
    while (const char *piece = reader(L, data, &size)) {
        if (!size) break;
        loaded.bytes.append(piece, size);
    }
    return 0;
}

Pieces split(const std::string &text, size_t parts) {
    Pieces pieces;
    size_t step = text.size() / parts + 1;
    for (size_t at = 0; at < text.size(); at += step) pieces.parts.push_back(text.substr(at, step));
    return pieces;
}

bool copyOver(char *bytes, const char *patched, size_t size) { memcpy(bytes, patched, size); return true; }

// Where each table entry is in an extraction of the paks (in table order).
const char *const extractedPaths[] = {
    "Shared/Mods/Shared/Scripts/thoth/helpers/CommonConditions.khn",
    "Shared/Mods/Shared/Scripts/thoth/helpers/CommonConditionsDev.khn",
    "Gustav/Mods/Honour/Scripts/thoth/helpers/CommonConditions.khn",
    "Game/Scripts/thoth/generateConditionString.khn",
    "Gustav/Public/GustavDev/AI/Archetypes/act3_WYR_Gortash_ranged.txt",
    "Gustav/Public/Gustav/AI/Archetypes/mindflayer.txt",
};
static_assert(sizeof extractedPaths / sizeof *extractedPaths == sizeof Fixes::files / sizeof *Fixes::files,
    "one extracted path per table entry");
}

int main(int argc, char **argv) {
    CHECK(Fixes::ScriptCandidate("@Public/Shared/Scripts/thoth/helpers/CommonConditions.khn") ==
          "thoth/helpers/CommonConditions.khn", "path chunk");
    CHECK(!Fixes::ScriptCandidate("@Mods\\Shared\\Scripts\\thoth/helpers/CommonConditionsDev.khn").empty(), "backslash before the suffix");
    CHECK(!Fixes::ScriptCandidate("@Scripts/thoth/generateConditionString.khn").empty(), "preprocessor");
    CHECK(Fixes::ScriptCandidate("Scripts/thoth/generateConditionString.khn").empty(), "a chunk without '@' is source text");
    CHECK(Fixes::ScriptCandidate("@helpers/MyCommonConditions.khn").empty(), "suffix of another name");
    CHECK(Fixes::ScriptCandidate("@other/CommonConditions.khn").empty(), "same file name in another folder");
    CHECK(Fixes::ScriptCandidate("@thoth/helpers/CommonConditions.khn.bak").empty(), "other extension");
    CHECK(Fixes::ScriptCandidate(nullptr).empty(), "null chunk name");
    CHECK(Fixes::Candidate(Kind::Script, "Public/Gustav/AI/Archetypes/mindflayer.txt").empty(), "data is not a script");
    CHECK(!Fixes::Candidate(Kind::Data, "Public/Gustav/AI/Archetypes/mindflayer.txt").empty(), "archetype path");
    CHECK(Fixes::Candidate(Kind::Data, "Public/Gustav/Stats/mindflayer.txt").empty(), "same file name outside AI/Archetypes");

    // Unrelated chunks reach lua_load with BG3's own reader untouched.
    Pieces condition{{"return Tagged('X')"}};
    int skips = 0;
    Fixes::Result reason = Fixes::Result::Patched;
    auto record = [&](std::string_view, Fixes::Result result) { ++skips; reason = result; };
    Fixes::LoadFixed(fakeLoad, nullptr, readPieces, &condition, "=condition", "t", record);
    CHECK(loaded.reader == readPieces && loaded.data == &condition, "unrelated chunk keeps its reader");
    CHECK(skips == 0, "unrelated chunk is not reported");

    // A named script with other contents (a mod's) loads byte for byte, reported.
    const std::string modded = "function CanUseWeaponActions()\r\n    return not Tagged('AI_BLOCKWEAPONACTIONS') | Player()\r\nend\r\n";
    Pieces moddedPieces = split(modded, 4);
    Fixes::LoadFixed(fakeLoad, nullptr, readPieces, &moddedPieces, "@Mods/X/Scripts/thoth/helpers/CommonConditions.khn", "t", record);
    CHECK(loaded.bytes == modded, "unknown contents load unchanged");
    CHECK(skips == 1 && reason == Fixes::Result::Unknown, "unknown contents are reported as Unknown");

    // Data patching leaves unrelated and unknown files alone.
    std::string other = "MODIFIER_HIT_CHANCE_STUPIDITY 1.0\r\n";
    skips = 0;
    Fixes::PatchData("Public/Gustav/AI/Archetypes/melee.txt", other.data(), other.size(), copyOver, record);
    CHECK(skips == 0 && other == "MODIFIER_HIT_CHANCE_STUPIDITY 1.0\r\n", "unrelated archetype untouched");
    Fixes::PatchData("Public/Gustav/AI/Archetypes/mindflayer.txt", other.data(), other.size(), copyOver, record);
    CHECK(skips == 1 && reason == Fixes::Result::Unknown && other == "MODIFIER_HIT_CHANCE_STUPIDITY 1.0\r\n",
        "unknown archetype untouched and reported");

    for (const Fixes::File &file : Fixes::files)
        for (size_t i = 0; i < file.count; ++i) {
            const Fixes::Edit &edit = file.edits[i];
            CHECK(edit.from != edit.to && !edit.from.empty(), "edit %zu of %.*s changes something", i,
                int(file.path.size()), file.path.data());
            CHECK(file.kind == Kind::Script || edit.from.size() == edit.to.size(),
                "data edit %zu of %.*s keeps the length", i, int(file.path.size()), file.path.data());
        }

    struct stat info;
    const char *root = argc > 1 ? argv[1] : nullptr;
    if (!root || stat(root, &info) != 0) {
        std::printf("Script fixes: matching, pass-through and data patching passed; no extracted files%s%s, table check skipped.\n",
            root ? " at " : "", root ? root : "");
        return failures ? 1 : 0;
    }
    size_t index = 0;
    for (const Fixes::File &file : Fixes::files) {
        const std::string relative = extractedPaths[index++];
        const std::string path = std::string(root) + "/" + relative;
        std::ifstream stream(path, std::ios::binary);
        CHECK(stream.good(), "missing %s", path.c_str());
        if (!stream.good()) continue;
        std::stringstream contents;
        contents << stream.rdbuf();
        const std::string source = contents.str();
        CHECK(Fixes::Sha256(source) == file.sha256, "%s: hash %s", path.c_str(), Fixes::Sha256(source).c_str());
        std::string expected = source;
        CHECK(Fixes::ApplyEdits(file, expected), "%s: every edit matches once", path.c_str());
        CHECK(expected != source, "%s: edits change it", path.c_str());
        skips = 0;
        if (file.kind == Kind::Script) {
            // Through the hook path, streamed in pieces, as BG3 would load it.
            Pieces pieces = split(source, 3);
            const std::string chunk = "@Public/" + relative;
            Fixes::LoadFixed(fakeLoad, nullptr, readPieces, &pieces, chunk.c_str(), "t", record);
            CHECK(skips == 0, "%s was not patched", path.c_str());
            CHECK(loaded.bytes == expected, "%s: patched bytes", path.c_str());
            CHECK(loaded.chunk == chunk.c_str(), "%s keeps its chunk name", path.c_str());
        } else {
            // In place, then again on the already patched shared copy.
            std::string buffer = source;
            const std::string name = "Public/" + relative;
            Fixes::PatchData(name, buffer.data(), buffer.size(), copyOver, record);
            CHECK(skips == 0 && buffer == expected, "%s: patched in place", path.c_str());
            Fixes::PatchData(name, buffer.data(), buffer.size(), copyOver, record);
            CHECK(skips == 0 && buffer == expected, "%s: a second read is left as patched, unreported", path.c_str());
            Fixes::PatchData(name, buffer.data(), buffer.size(),
                [](char *, const char *, size_t) { return false; }, record);
            CHECK(skips == 0, "%s: already patched needs no write", path.c_str());
            std::string fresh = source;
            Fixes::PatchData(name, fresh.data(), fresh.size(), [](char *, const char *, size_t) { return false; }, record);
            CHECK(skips == 1 && reason == Fixes::Result::NotWritable && fresh == source,
                "%s: unwritable memory is reported and left", path.c_str());
        }
    }
    std::printf("Script fixes: matching, pass-through, data patching and %zu shipped files passed.\n", index);
    return failures ? 1 : 0;
}
