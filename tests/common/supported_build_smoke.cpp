#include "common/native/SupportedBuild.h"
#include <cstdio>
#include <limits>

using BG3MFXBuild::Island;
using BG3MFXBuild::Islands::valid;
constexpr Island adjacent[] = {{0, 32}, {32, 16}};
constexpr Island overlap[] = {{0, 32}, {28, 16}};
constexpr Island misaligned[] = {{2, 16}};
constexpr Island partialInstruction[] = {{0, 15}};
constexpr Island empty[] = {{0, 0}};
constexpr Island pastPadding[] = {{0x4000, 4}};
constexpr Island overflow[] = {{4, std::numeric_limits<size_t>::max() - 3}};
static_assert(valid(adjacent, 2), "Adjacent reservations are allowed");
static_assert(!valid(overlap, 2), "Overlapping native stubs must be rejected");
static_assert(!valid(misaligned, 1) && !valid(partialInstruction, 1), "Instructions require alignment");
static_assert(!valid(empty, 1) && !valid(pastPadding, 1) && !valid(overflow, 1), "Invalid ranges must fail closed");
int main() { std::puts("Supported-build island guards: adjacency, overlap, alignment, bounds and overflow passed."); }
