#!/usr/bin/env bash
# rubyrequirecheck.sh — kParserVer 81 gate: RUBY `require_relative` / `require` / `load` are dependencies.
#
# Two rules behind three spellings, told apart by a LEADING DOT rather than a new prefix vocabulary
# (ingest_relations.h::rubyRequireTarget normalizes `require_relative "x"` to `./x`):
#   * a dotted specifier is relative to the requiring FILE — the exact analogue of a C quote-include;
#   * a bare specifier is searched on $LOAD_PATH, which this tool does not have. resolve.h probes the
#     crawl root and the four directories that are on it in practice (lib/ app/ test/ spec/), and every
#     probe is unique-or-degrade.
#
# Fixture test/rubyrequirefix (main.rb, one shape per line):
#   require_relative 'lib/helper'   -> lib/helper.rb    file-relative
#   require_relative './sib'        -> sib.rb           already dotted
#   require 'lib/helper'            -> lib/helper.rb    the OTHER rule, same file
#   require 'json'                  -> no edge          a gem outside the tree
#   load 'tool.rb'                  -> tool.rb          Kernel#load, same load-path rule
#   require 'shared'                -> no edge          AMBIGUOUS: ./shared.rb and lib/shared.rb answer
#   require some_variable           -> not captured     no string literal to read
#   autoload :Late, 'lib/helper'    -> not captured     DISCLOSED FLOOR: the path is argument TWO
#   + require_relative inside a module body, a method body, a begin/rescue LoadError pair, and an if
#   decoy/helper.rb                 -> a same-BASENAME file no rule can reach
#
# Usage:  test/rubyrequirecheck.sh   |   RIPWIRE_BIN=asan/ripwire test/rubyrequirecheck.sh
# Exit:   0 = clean · 1 = an arm failed · 2 = usage / missing prerequisite

set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
FIX="$ROOT/test/rubyrequirefix"
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }
[ -d "$FIX" ] || { echo "no test/rubyrequirefix — fixture missing"; exit 2; }
echo "rubyrequirecheck: BIN=$BIN  FIX=$FIX"

"$BIN" "$FIX" --deps --no-cache >"$TMP/deps" 2>/dev/null
DEPS="$( cat "$TMP/deps" )"

# ── 1. CAPTURE + the two-rule encoding ────────────────────────────────────────────────────────────────
printf '%s' "$DEPS" | grep -q '<inc t="./lib/helper"/>' \
    && ok 'encoding: require_relative "lib/helper" is recorded as "./lib/helper" (file-relative rule)' \
    || no "encoding: the require_relative specifier was not dot-normalized: $( printf '%s' "$DEPS" | grep -oE '<inc t="[^"]*"/>' | tr '\n' ' ' )"
printf '%s' "$DEPS" | grep -q '<inc t="lib/helper"/>' \
    && ok 'encoding: require "lib/helper" stays BARE (load-path rule) — the two are distinguishable' \
    || no "encoding: the bare require specifier is missing or was dot-normalized too"
for t in './sib' 'json' 'tool.rb' 'shared' 'optional_gem'; do
    printf '%s' "$DEPS" | grep -qF "<inc t=\"$t\"/>" \
        && ok "capture: <inc t=\"$t\"/>" \
        || no "capture: no <inc t=\"$t\"/> row"
done
printf '%s' "$DEPS" | grep -q '<f p="main.rb" includes="11"' \
    && ok 'capture: exactly 11 directives — `require some_variable` and `autoload` are NOT invented' \
    || no "capture: directive count wrong: $( printf '%s' "$DEPS" | grep -oE '<f p="main.rb" includes="[0-9]*"' )"

# ── 2. RESOLUTION ─────────────────────────────────────────────────────────────────────────────────────
printf '%s' "$DEPS" | grep -q '<f p="lib/helper.rb" afferent="2"/>' \
    && ok 'resolve: BOTH rules land on lib/helper.rb (afferent="2") — file-relative and load-path agree' \
    || no "resolve: lib/helper.rb afferent wrong: $( printf '%s' "$DEPS" | grep -oE '<f p="lib/helper.rb" afferent="[0-9]*"/>' )"
for f in sib tool; do
    printf '%s' "$DEPS" | grep -q "<f p=\"$f.rb\" afferent=\"1\"/>" \
        && ok "resolve: $f.rb has its importer" || no "resolve: $f.rb has no importer"
done
# the container arms: module body / method body / rescue arm / if arm, one file each
for f in nested/deep lib/lazy lib/fallback lib/modern; do
    printf '%s' "$DEPS" | grep -q "<f p=\"$f.rb\" afferent=\"1\"/>" \
        && ok "container arm: $f.rb reached (module / method / rescue / if body)" \
        || no "container arm: $f.rb has no importer — the walk did not enter that container kind"
done

# ── 3. MUTATION CONTROLS ──────────────────────────────────────────────────────────────────────────────
# (a) unique-or-degrade: `require "shared"` is answered by ./shared.rb AND lib/shared.rb. main.rb's cone
#     is therefore exactly {itself + 7 resolved files} = 8; a resolver that picked one would make it 9.
printf '%s' "$DEPS" | grep -q '<f p="main.rb" includes="11" afferent="0" instab="1.00" transitive="8">' \
    && ok 'mutation control: the ambiguous `require "shared"` degrades — cone is 8, not 9' \
    || no "mutation control: the ambiguous require resolved: $( printf '%s' "$DEPS" | grep -oE '<f p="main.rb"[^>]*>' )"
printf '%s' "$DEPS" | grep -qE '<f p="(lib/)?shared.rb" afferent=' \
    && no "mutation control: one of the two shared.rb files took the ambiguous edge" \
    || ok 'mutation control: neither shared.rb gained an importer'
# (b) no basename fallback
printf '%s' "$DEPS" | grep -q '<f p="decoy/helper.rb" afferent=' \
    && no "mutation control: decoy/helper.rb gained an importer — a basename fallback crept in" \
    || ok 'mutation control: decoy/helper.rb has no importer (path-precise, never basename)'
# (c) the DISCLOSED FLOOR: `autoload :Late, "lib/helper"` names a real in-tree file in argument TWO and is
#     deliberately not captured. If a later round adds it, this arm fails and the doc comment must move
#     with it — a floor nobody ever sees expire is a floor that quietly becomes a lie.
printf '%s' "$DEPS" | grep -q '<f p="main.rb" includes="11"' \
    && ok 'floor: autoload is NOT captured (11 directives, not 12) — the stated floor still holds' \
    || no "floor: the directive count moved — autoload may now be captured; update the floor note"

# ── 4. CAPABILITY ─────────────────────────────────────────────────────────────────────────────────────
printf '%s' "$DEPS" | grep -q '<health files="11" dep_files="11"' \
    && ok 'capability: all 11 .rb files are dependency-capable (dep_files == files)' \
    || no "capability: dep_files wrong: $( printf '%s' "$DEPS" | grep -oE '<health [^/]*/>' )"
printf '%s' "$DEPS" | grep -qE 'dep_langs="[^"]*,rb[,"]' \
    && ok 'capability: <health dep_langs=> discloses rb in the capable set' \
    || no "capability: dep_langs= does not name rb"

# ── 5. root spelling, determinism, warm == cold, well-formed XML ──────────────────────────────────────
( cd "$FIX" && "$BIN" . --deps --no-cache 2>/dev/null ) | sed 's/ root="[^"]*"//' >"$TMP/dots"
"$BIN" "$FIX" --deps --no-cache 2>/dev/null | sed 's/ root="[^"]*"//' >"$TMP/abs"
cmp -s "$TMP/dots" "$TMP/abs" \
    && ok 'root spelling: a relative and an absolute crawl root resolve identically' \
    || { no 'root spelling: the load-path probes are anchored differently under the two spellings'; diff "$TMP/dots" "$TMP/abs" | head -4; }
"$BIN" "$FIX" --deps --no-cache >"$TMP/d1" 2>/dev/null
"$BIN" "$FIX" --deps --no-cache >"$TMP/d2" 2>/dev/null
cmp -s "$TMP/d1" "$TMP/d2" && ok "deterministic (two --no-cache runs identical)" || no "non-deterministic"
"$BIN" "$FIX" --deps --cache="$TMP/c.bin" >"$TMP/cold" 2>/dev/null
"$BIN" "$FIX" --deps --cache="$TMP/c.bin" >"$TMP/warm" 2>/dev/null
cmp -s "$TMP/cold" "$TMP/warm" && ok "warm == cold (directives survive the cache round-trip)" || no "warm != cold"
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$TMP/d1" 2>/dev/null && ok "xml well-formed" || no "xml malformed"
else
    ok "xml well-formed (xmllint absent — skipped)"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
