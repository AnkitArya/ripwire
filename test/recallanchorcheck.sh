#!/usr/bin/env bash
# recallanchorcheck.sh — L4.3 section-anchor gate for --recall's section-granular bodies.
#
# The gap this closes: a section-granular recall bundle already discloses "[sections: K of M,
# section-granular; whole doc N B]" — but names no LOCATION, so an agent that wants to cite or re-open
# the section has to re-grep the doc to find where it starts. The fix exposes the boundary that was
# already computed (buildSectionGranularBody picks sections by [sigStartByte, endByte) spans) as a
# `lines="LO-HI"` anchor on the same note, one range per kept section in document order.
#
# ARM
#   A fixture with three disjoint-topic ## sections under one # root heading. A query that matches only
#   the middle section (Kafka) asserts:
#     (i)   the note carries a `lines="LO-HI[,…]"` anchor at all
#     (ii)  the ANSWERING section's LO-HI is among those anchors and matches the fixture's KNOWN heading
#           boundaries, computed INDEPENDENTLY of ripwire (by locating heading lines in the fixture text
#           with a plain line scan) — not derived from ripwire's own internals, so this is a real
#           ground-truth check, not a tautology. Ground-truth rule, §RP3.1's own-prose rule: a section
#           runs from its own heading line to the line before the next heading OF ANY DEPTH (or EOF).
#     (iii) EVERY emitted anchor is a valid own-prose span from that same independent table — an
#           off-by-one on any served unit fails, not just on the first one.
#     (iv)  no anchor contains another: own-prose units TILE, which is the property that replaced the
#           old overlap loop. (This arm and (iii) together are strictly stronger than the "exactly one
#           range" count they replaced, which was really an assertion about the superseded overlap rule
#           — under it an ancestor and a descendant could never both be served, so the root heading's
#           own prose was unreachable at any budget.)
#     (v)   budget/determinism: the SAME anchor on two runs, byte-identical.
#   RED proof: the pre-patch binary's note has no `lines="` attribute at all — grep absence, not a
#   wrong value, is the pre-fix failure mode for a brand-new disclosure surface.
#
# Usage:  test/recallanchorcheck.sh [BIN]   |   RIPWIRE_BIN=asan/ripwire test/recallanchorcheck.sh
# Exits non-zero on any failure.

set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
fail=0
ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 2; }

echo "recallanchorcheck: BIN=$BIN"

TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"; mkdir -p "$R"

cat >"$R/doc.md" <<'EOF'
# Root doc

Intro line, unrelated topics not matching query at all here for filler padding words.

## Kafka Section

Kafka consumer group rebalancing, partition assignment, offset commits and the sticky assignor for kafka streams.

## Render Section

Font glyph rasterization, subpixel antialiasing, hinting and bezier curve tessellation for render pipeline.

## Cache Section

LRU cache eviction, doubly-linked list plus hashmap, TTL expiry for the in-memory cache.
EOF

# ─── ground truth, computed independently of ripwire: heading lines + the OWN-PROSE span rule ─────────
# The rule pinned here is §RP3.1's: a section's emitted unit runs from its own heading line to the line
# before the NEXT heading OF ANY DEPTH (or EOF) — its own prose, not its subtree. It is computed by a
# plain line scan over the fixture, never read back out of ripwire, so this stays a ground-truth check
# rather than a tautology. A trailing newline is stripped first so the last section's hi is its last
# CONTENT line, which is what mapping the final byte back to a line number yields.
GROUND="$( python3 - "$R/doc.md" <<'PY'
import sys
text = open( sys.argv[1] ).read()
if text.endswith( "\n" ):
    text = text[ :-1 ]
lines = text.split( "\n" )
heads = [ i + 1 for i, l in enumerate( lines ) if l.startswith( "#" ) and l.lstrip( "#" ).startswith( " " ) ]
spans = [ "%d-%d" % ( h, ( heads[ k + 1 ] - 1 ) if k + 1 < len( heads ) else len( lines ) )
          for k, h in enumerate( heads ) ]
print( next( s for s, h in zip( spans, heads ) if "Kafka" in lines[ h - 1 ] ) )
print( " ".join( spans ) )
PY
)"
KAFKA_SPAN="$( printf '%s\n' "$GROUND" | sed -n 1p )"
ALL_SPANS="$( printf '%s\n' "$GROUND" | sed -n 2p )"
echo "ground truth (independently computed): Kafka own-prose span $KAFKA_SPAN; all spans: $ALL_SPANS"

recall(){ perl -e 'alarm 20; exec @ARGV' "$BIN" "$R" --recall="kafka consumer offset rebalancing partition" --no-cache "$@" 2>/dev/null; }

echo
echo "=== section-granular note carries a lines=\"LO-HI\" anchor matching ground truth ==="
OUT="$( recall )"
NOTE="$( printf '%s' "$OUT" | grep -oE '\[sections: [^]]*\]' )"
[ -n "$NOTE" ] && ok "section-granular note present: $NOTE" || { no "no [sections: …] note — fixture did not trigger section-granular recall"; printf '%s\n' "$OUT" | head -5; }

ANCHOR="$( printf '%s' "$NOTE" | grep -oE 'lines="[0-9]+-[0-9]+(,[0-9]+-[0-9]+)*"' )"
if [ -n "$ANCHOR" ]; then
    ok "lines= anchor present: $ANCHOR (base: no such attribute existed before this patch)"
else
    no "no lines=\"…\" anchor in the note — the section boundary is not exposed: $NOTE"
fi

GOT_RANGES="$( printf '%s' "$ANCHOR" | grep -oE '[0-9]+-[0-9]+' )"

# (ii) the ANSWERING section is anchored at exactly its independently-computed span. This used to read
# "the FIRST range equals ground truth", which silently also asserted that ripwire kept exactly one
# section — the pre-§RP3.1 overlap rule, where an ancestor and a descendant could never both be served.
# Under own-prose units the root heading's own prose is a unit of its own and legitimately precedes the
# Kafka unit, so position is no longer the check. Exact span equality still is, and that is the arm that
# was ever doing the work.
if printf '%s\n' "$GOT_RANGES" | grep -qx "$KAFKA_SPAN"; then
    ok "the answering (Kafka) section is anchored at its independently-computed own-prose span $KAFKA_SPAN"
else
    no "answering section's span $KAFKA_SPAN is not among the anchors: $ANCHOR"
fi

# (iii) every emitted range is a VALID own-prose span from the independent table — not merely a
# plausible-looking pair of numbers. Catches an off-by-one in the boundary rule on ANY emitted unit,
# which the single-range check could not see.
BAD=""
for r in $GOT_RANGES; do
    case " $ALL_SPANS " in
        *" $r "* ) ;;
        *        ) BAD="$BAD $r";;
    esac
done
[ -z "$BAD" ] && ok "every anchor is an own-prose heading span from the independent table ($ALL_SPANS)" \
              || no "anchor(s) not a valid own-prose span:$BAD (valid: $ALL_SPANS)"

# (iv) §RP3.1's tiling property: own-prose units never nest, so no anchor may contain another. This is
# the property that replaced the overlap loop, and it is worth more than counting the ranges.
NESTED="$( printf '%s\n' "$GOT_RANGES" | python3 -c '
import sys
rs = [ tuple( map( int, l.split( "-" ) ) ) for l in sys.stdin.read().split() ]
print( sum( 1 for i, a in enumerate( rs ) for j, b in enumerate( rs ) if i != j and a[0] <= b[0] and b[1] <= a[1] ) )' )"
[ "$NESTED" = "0" ] && ok "no anchor range contains another (own-prose units tile, never nest)" \
                    || no "$NESTED nested anchor pair(s) — units must be disjoint: $ANCHOR"

# ─── determinism ────────────────────────────────────────────────────────────────────────────────────
echo
echo "=== determinism — same input, byte-identical ==="
recall >"$TMP/d1"
recall >"$TMP/d2"
cmp -s "$TMP/d1" "$TMP/d2" && ok "byte-identical across two runs" || no "NON-deterministic across two runs"

echo
[ "$fail" -eq 0 ] && { echo "recallanchorcheck: ALL PASS"; exit 0; }
echo "recallanchorcheck: FAILURES present"; exit 1
