#!/usr/bin/env bash
# recallpassagecheck.sh — the passage-serving gate for --recall. The defect it pins: a document's
# ranked sections are picked correctly, then thrown away by a document-order prefix cut before the
# reader ever sees them (see the per-arm table below). WRITTEN BEFORE THE FIX EXISTED — CLAUDE.md non-negotiable #1 ("write the gate before the code it measures"). Lane L1 builds
# src/recall.h's section path against this gate as the contract; this file and
# test/fixtures/recallpassage/** are that lane's whole footprint.
#
# MEASURED against build/ripwire at 113c7aea (the main tip this design branched from), 2026-09-08, on
# macOS/AppleClang — reproduced with the exact commands each arm below runs. Recorded here so a future
# reader (L1, or anyone re-running this gate) can tell a REAL fix from a gate that was always green:
#
#   ARM  TODAY   WHAT HAPPENED
#   P1   FAIL    large_late_answer.md (340,821 B; one matching file), target section (890 B, heading at
#                line 858) sits at the 95th percentile of 300 headed sections, all of which score > 0.
#                --max-tokens=2000: 3,963 B emitted, the answer sentinel is ABSENT. buildSectionGranularBody
#                keeps 300 of 301 sections (all positive-scoring, none overlap — flat H2 structure), then
#                RE-SORTS them to document order and concatenates; truncateRecallBody prefix-cuts that
#                document-ordered string, landing inside "Section 0000" — nowhere near "Section 0285",
#                even though ranking (verified via --for) puts Section 0285 at r=1.
#   P2   FAIL    same fixture, --max-tokens in {1500,3000,8000,40000}: sentinel ABSENT at ALL FOUR —
#                even 84,658 B (40000 tok, ~95x the 890 B the answer alone would need) does not reach it.
#                Not "present only at large budgets" — present at NONE of them.
#   P3   PASS    small_fits.md (261 B; the matched content is comfortably under the 8000-tok default):
#                output is byte-identical to test/fixtures/recallpassage/small_fits.golden.
#
#                THE ORIGINAL SPEC FOR THIS ARM WAS WRONG, and the arm is the evidence. It asked for
#                byte-identity against the PRE-FIX binary whenever the budget does not bind — but the
#                fix redefines what a unit IS, so the two cannot both hold. On this very fixture the pre-fix overlap loop
#                dropped `# Widget cache notes` because its span (1-9) contained the matching
#                subsection; that heading's own prose carries "widget" and "cache" and was unreachable
#                at ANY budget. Post-fix it is a two-line unit of its own and the output legitimately
#                grows by those two lines. The golden is therefore re-captured from the POST-fix
#                binary, and what this arm pins now is the property that is both available and worth
#                having: a non-binding budget is byte-STABLE — no unit selection, note form or lines=
#                list may move while nothing is being cut. That still fails loudly on accidental
#                drift; it just no longer asserts the equivalence the fix was commissioned to break.
#   P4   FAIL    the disclosed `lines="..."` attribute on large_late_answer.md is BYTE-IDENTICAL at
#                --max-tokens=3000 and --max-tokens=200000 (299 ranges, same text, both times) — it is
#                computed once in LOAD before the budget is known (the pre-fix LOAD path), so it
#                never moves regardless of how much the budget grows.
#   P5   FAIL    (a) NO --recall output today carries a `dropped_by_budget=` attribute or the
#                "S of R selected (N in doc)" note shape the disclosure contract specifies — grep absence, not a wrong
#                value: the disclosure surface does not exist yet.
#                (b) at --max-tokens=2000, `lines=` names 300 ranges; checked against the fixture file
#                DIRECTLY (ground truth independent of ripwire, matching recallanchorcheck.sh's
#                convention) only 1 of the 300 named ranges (Section 0000, the document's first) is
#                actually present in the emitted body. 299 named ranges describe text that was never sent.
#   P6   PASS    the same command run twice at --max-tokens=4000 is byte-identical — the standing
#                determinism contract (unrelated to this defect) and it must stay green throughout.
#   P7   FAIL    nested_headings.md, --max-tokens=1000000 (budget not binding — isolates defect B from
#                defect A): the one kept range is `lines="11-23"` ("### Beacon module") and it CONTAINS
#                line 16 ("#### Vortex tuning procedure", Beacon's own child, and the section that
#                literally contains the query's exact phrase). Vortex ranks #2 by --for and gets dropped
#                by buildSectionGranularBody's overlap-drop as "overlapping" its kept parent — whose span
#                reaches to EOF because nothing follows it at an equal-or-shallower heading depth, so it
#                swallows every descendant it has (the ancestor-swallows-descendants root cause).
#   P8   PASS    degenerate_single.md, --max-tokens=500 (the doc's one matching section is bigger than
#                its share): shown=1, `[truncated: 422 of 15866 bytes]` is disclosed — nothing is silently
#                dropped to shown=0. A single-candidate document has no "front matter vs top-ranked unit"
#                distinction to get wrong, so today's document-order cut and the fix's rank-order cut
#                degenerate to the same cut here. Deliberately NOT where the defect shows; must stay
#                green after the fix too (the fix's own degenerate case).
#
# Usage:  RIPWIRE_BIN=build/ripwire bash test/recallpassagecheck.sh    (no positional arguments — this
#         repo's gates take none; see test/regression.sh's absorb loop, which is how this gate is run)
#         RIPWIRE_BIN=build_base/ripwire bash test/recallpassagecheck.sh   # a pre-fix binary must show
#                                                                           # the FAIL table above

set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${RIPWIRE_BIN:-$ROOT/build/ripwire}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
FIX="$ROOT/test/fixtures/recallpassage"
fail=0
ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 2; }
for f in large_late_answer.md nested_headings.md small_fits.md degenerate_single.md small_fits.golden; do
    [ -f "$FIX/$f" ] || { echo "missing fixture: $FIX/$f — regenerate test/fixtures/recallpassage/"; exit 2; }
done

echo "recallpassagecheck: BIN=$BIN"

TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT

# run DIR QUERY [extra ripwire flags...] — stdout is returned by the caller's redirect; stderr parked
# at $TMP/err. alarm-wrapped like every sibling recall*check.sh (a hung run must not hang the suite).
run(){
    local dir="$1" q="$2"
    shift 2
    perl -e 'alarm 60; exec @ARGV' "$BIN" "$dir" --recall="$q" --no-cache "$@" 2>"$TMP/err"
}

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Fixture corpora — each arm gets its OWN single-file directory so "1 relevant of 1 document files" is
# unambiguous and a separator's displayed path is always the fixture's bare filename, regardless of
# where $TMP happens to land.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
LARGE="$TMP/large"; mkdir -p "$LARGE"; cp "$FIX/large_late_answer.md" "$LARGE/"
NEST="$TMP/nest";   mkdir -p "$NEST";  cp "$FIX/nested_headings.md"  "$NEST/"
SMALL="$TMP/small"; mkdir -p "$SMALL"; cp "$FIX/small_fits.md"       "$SMALL/"
DEGEN="$TMP/degen"; mkdir -p "$DEGEN"; cp "$FIX/degenerate_single.md" "$DEGEN/"

Q_LARGE="turbine flux calibration offset drift"
Q_NEST="zephyr cascade beacon vortex"
Q_SMALL="widget cache eviction policy"
Q_DEGEN="granite orbital lumen cascade"
SENTINEL="answers the query exactly"

# ── P1 — reachability: the last-decile answer must be IN the output at a share far below the doc size
echo "  ---- P1 reachability ----"
run "$LARGE" "$Q_LARGE" --max-tokens=2000 > "$TMP/p1.out"; P1_RC=$?
P1_BYTES=$( wc -c < "$TMP/p1.out" | tr -d ' ' )
if [ "$P1_RC" = 0 ] && grep -q "$SENTINEL" "$TMP/p1.out"; then
    ok "P1 reachability: the answering section (rank #1, last decile of 300 sections) IS in the --max-tokens=2000 output ($P1_BYTES B of a 340821 B doc)"
else
    no "P1 reachability: --max-tokens=2000 (exit=$P1_RC, $P1_BYTES B) does not contain the answering section — ranked #1 by --for, never served"
fi
if [ "$P1_BYTES" -gt 0 ] && [ "$P1_BYTES" -lt 20000 ]; then
    ok "P1 share check: $P1_BYTES B is far below the 340821 B document — the reachability claim is not vacuous (a real, small budget was applied)"
else
    no "P1 share check: $P1_BYTES B is not a meaningfully small share of the 340821 B document"
fi

# ── P2 — ceiling sweep: present starting from the smallest budget that fits it, never only at large ones
echo "  ---- P2 ceiling sweep ----"
firstPresent=""
gapAfterFirst=0
for mt in 1500 3000 8000 40000; do
    run "$LARGE" "$Q_LARGE" --max-tokens="$mt" > "$TMP/p2_$mt.out"
    if grep -q "$SENTINEL" "$TMP/p2_$mt.out"; then
        present=yes
        [ -z "$firstPresent" ] && firstPresent="$mt"
    else
        present=no
        [ -n "$firstPresent" ] && gapAfterFirst=1
    fi
    printf '      max-tokens=%-7s answer_present=%s\n' "$mt" "$present"
done
if [ "$firstPresent" = "1500" ] && [ "$gapAfterFirst" = 0 ]; then
    ok "P2 ceiling sweep: the answer is present starting at the smallest swept budget (1500) and stays present at every larger one"
else
    no "P2 ceiling sweep: expected present from 1500 upward with no gaps; first_present=${firstPresent:-none} gap_after_first=$gapAfterFirst — see the per-budget rows above"
fi

# ── P3 — stability: a document whose units all fit is byte-identical to the captured golden. See the
# header note on P3 for why this golden is captured POST-fix and what the original spec for it got wrong.
echo "  ---- P3 stability (budget not binding) ----"
run "$SMALL" "$Q_SMALL" > "$TMP/p3.out"
if cmp -s "$TMP/p3.out" "$FIX/small_fits.golden"; then
    ok "P3 stability: small_fits.md (all matched content fits under the default 8000-tok ceiling) is byte-identical to test/fixtures/recallpassage/small_fits.golden"
else
    no "P3 stability: output differs from test/fixtures/recallpassage/small_fits.golden — with nothing being cut, not a byte may move"
    diff "$FIX/small_fits.golden" "$TMP/p3.out" | head -10 | sed 's/^/        | /'
fi

# ── P4 — monotonicity: the disclosed line-range set must be a non-shrinking, actually-growing chain
echo "  ---- P4 monotonicity of the disclosed lines= across budgets ----"
run "$LARGE" "$Q_LARGE" --max-tokens=3000   > "$TMP/p4_small.out"
run "$LARGE" "$Q_LARGE" --max-tokens=200000 > "$TMP/p4_big.out"
P4_LINE="$( python3 - "$TMP/p4_small.out" "$TMP/p4_big.out" <<'PY'
import sys, re
def ranges_of(path):
    text = open(path, encoding="utf-8").read()
    m = re.search(r'lines="([^"]*)"', text)
    return set(m.group(1).split(",")) if m and m.group(1) else set()
small = ranges_of(sys.argv[1])
big   = ranges_of(sys.argv[2])
print(f"subset={int(small.issubset(big))} grew={int(len(big) > len(small))} small_n={len(small)} big_n={len(big)}")
PY
)"
echo "      $P4_LINE"
if printf '%s' "$P4_LINE" | grep -q '^subset=1 grew=1 '; then
    ok "P4 monotonicity: the emitted line-range set only grows as --max-tokens grows (3000 -> 200000): $P4_LINE"
else
    no "P4 monotonicity: the disclosed lines= set does not strictly grow with the budget (3000 vs 200000): $P4_LINE — a set that never moves is not a chain, it is a constant pre-truncation dump"
fi

# ── P5 — disclosure: S/R/N and dropped_by_budget= must exist and be self-consistent with the body
echo "  ---- P5 disclosure self-consistency ----"
run "$LARGE" "$Q_LARGE" --max-tokens=2000 > "$TMP/p5.out"
if grep -qE 'sections: [0-9]+ of [0-9]+ selected \([0-9]+ in doc\)' "$TMP/p5.out" && grep -qE 'dropped_by_budget=[0-9]+' "$TMP/p5.out"; then
    ok "P5a format: the note carries the disclosure contract's 'S of R selected (N in doc)' and dropped_by_budget= fields"
else
    no "P5a format: the note does not carry the disclosure contract's 'S of R selected (N in doc)' / dropped_by_budget= fields — the disclosure surface does not exist"
fi
P5_LINE="$( python3 - "$FIX/large_late_answer.md" "$TMP/p5.out" <<'PY'
import sys, re
fixlines = open(sys.argv[1], encoding="utf-8").read().split("\n")
out = open(sys.argv[2], encoding="utf-8").read()
m = re.search(r'lines="([^"]*)"', out)
ranges = m.group(1).split(",") if m and m.group(1) else []
present = 0
for r in ranges:
    lo = int(r.split("-")[0])
    heading = fixlines[lo - 1] if 0 < lo <= len(fixlines) else None
    if heading and heading in out:
        present += 1
print(f"claimed={len(ranges)} actually_present={present}")
PY
)"
echo "      $P5_LINE"
P5_CLAIMED="$( printf '%s' "$P5_LINE" | grep -oE 'claimed=[0-9]+'         | grep -oE '[0-9]+' )"
P5_PRESENT="$( printf '%s' "$P5_LINE" | grep -oE 'actually_present=[0-9]+' | grep -oE '[0-9]+' )"
if [ -n "$P5_CLAIMED" ] && [ "$P5_CLAIMED" -gt 0 ] && [ "$P5_PRESENT" = "$P5_CLAIMED" ]; then
    ok "P5b consistency: every one of the $P5_CLAIMED lines= ranges is actually present in the emitted body (ground truth read from the fixture file directly)"
else
    no "P5b consistency: lines= claims $P5_CLAIMED ranges but only $P5_PRESENT are actually present in the emitted body — the disclosure names content that was never served"
fi

# ── P6 — determinism: the standing contract, re-asserted on the section-passage path
echo "  ---- P6 determinism ----"
run "$LARGE" "$Q_LARGE" --max-tokens=4000 > "$TMP/p6a.out"
run "$LARGE" "$Q_LARGE" --max-tokens=4000 > "$TMP/p6b.out"
if cmp -s "$TMP/p6a.out" "$TMP/p6b.out"; then
    ok "P6 determinism: two runs at --max-tokens=4000 are byte-identical"
else
    no "P6 determinism: two runs at --max-tokens=4000 differ"
fi

# ── P7 — nesting: with §3.1 in place, no emitted range may contain another heading's line
echo "  ---- P7 nesting (defect B) ----"
run "$NEST" "$Q_NEST" --max-tokens=1000000 > "$TMP/p7.out"
# ground truth, computed independently of ripwire (matches recallanchorcheck.sh's convention): every
# markdown heading's own line number, via a plain scan of the fixture text.
HEAD_LINES="$( grep -n '^#' "$FIX/nested_headings.md" | cut -d: -f1 | tr '\n' ' ' )"
P7_LINE="$( python3 - "$TMP/p7.out" "$HEAD_LINES" <<'PY'
import sys, re
out = open(sys.argv[1], encoding="utf-8").read()
headings = [int(x) for x in sys.argv[2].split()]
m = re.search(r'lines="([^"]*)"', out)
ranges = []
if m and m.group(1):
    for r in m.group(1).split(","):
        lo, hi = r.split("-")
        ranges.append((int(lo), int(hi)))
violations = [(lo, hi, h) for lo, hi in ranges for h in headings if h != lo and lo < h <= hi]
if violations:
    print("VIOLATION " + ";".join(f"{lo}-{hi}_contains_heading@{h}" for lo, hi, h in violations))
else:
    print("CLEAN ranges=" + ",".join(f"{lo}-{hi}" for lo, hi in ranges))
PY
)"
echo "      $P7_LINE"
if printf '%s' "$P7_LINE" | grep -q '^CLEAN'; then
    ok "P7 nesting: $P7_LINE — no emitted range swallows another heading's line"
else
    no "P7 nesting: $P7_LINE — an emitted range CONTAINS a nested heading's line (defect B: the ancestor swallowed its descendant)"
fi

# ── P8 — degenerate: a single unit bigger than the whole share is prefix-cut, never dropped to zero
echo "  ---- P8 degenerate ----"
run "$DEGEN" "$Q_DEGEN" --max-tokens=500 > "$TMP/p8.out"
SHOWN="$( head -1 "$TMP/p8.out" | grep -oE ' shown=[0-9]+' | grep -oE '[0-9]+' )"
if [ "$SHOWN" = "1" ] && grep -qE '\[truncated: [0-9]+ of [0-9]+ bytes' "$TMP/p8.out"; then
    ok "P8 degenerate: shown=1 and the oversized single unit is disclosed as [truncated: N of M bytes], never silently dropped to shown=0"
else
    no "P8 degenerate: shown=${SHOWN:-<none>} and/or no [truncated: ...] disclosure: $( head -1 "$TMP/p8.out" )"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES ABOVE"
exit "$fail"
