#!/usr/bin/env bash
# skilldescbudgetcheck.sh — every skill description fits the client budget it is actually rendered under.
#
# Issue #49 (2026-09-07): Codex renders the skill catalog under a TOTAL budget (2% of the context window,
# or 8,000 chars) and, on overflow, hands description characters out round-robin — every over-long
# description ends at the same count (350 in the reporter's install) and the tail, where the routing
# boundaries lived, is what vanishes. Claude Code lists under 1% of the context window and caps an entry
# at 1,536. The registered design ceiling (docs/EVALS.md "Skill descriptions under a client budget") is
# 320 normalized characters per description — 30 under the observed cut, so the head IS the description —
# and 4,800 for the whole set, so the eighteen together stay a minority of any of those budgets.
# Length = the YAML content (whitespace-normalized, block-scalar marker excluded), exactly what a client
# reads; bench/skilldesc_budget.py is the measurement and this gate's body.
set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
fail=0
ok()  { echo "  ok   $*"; }
no()  { echo "  FAIL $*"; fail=1; }

out="$( python3 "$ROOT/bench/skilldesc_budget.py" "$ROOT/skills" --limit=320 2>&1 )"; rc=$?
summary="$( printf '%s\n' "$out" | tail -1 )"
printf '%s\n' "$out" | sed 's/^/    /'
[ "$rc" -eq 0 ] \
    && ok "every skill description is at or under 320 normalized characters" \
    || no "a skill description exceeds 320 normalized characters — the head cut would drop its routing boundary ($summary)"

total="$( printf '%s' "$summary" | sed -n 's/.* total=\([0-9]*\).*/\1/p' )"
count="$( printf '%s' "$summary" | sed -n 's/.*skills=\([0-9]*\).*/\1/p' )"
[ -n "$total" ] && [ "$total" -le 4800 ] \
    && ok "set total ${total} chars over ${count} skills (ceiling 4800)" \
    || no "set total ${total:-?} chars exceeds the 4800 ceiling — the skills as a set crowd out every other skill the user installs"

# the measurement must agree with the gate's own notion of a description: a description written as a
# folded block scalar and the same text inline must measure identically (the > marker is not content)
tmp="$( mktemp -d )"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/a/ripwire-x" "$tmp/a/ripwire-y"
printf -- '---\nname: ripwire-x\ndescription: >\n  one two   three\n  four\n---\nbody\n' > "$tmp/a/ripwire-x/SKILL.md"
printf -- '---\nname: ripwire-y\ndescription: one two three four\n---\nbody\n' > "$tmp/a/ripwire-y/SKILL.md"
lens="$( python3 "$ROOT/bench/skilldesc_budget.py" "$tmp/a" --limit=320 | awk 'NF==3{print $1}' | sort -u | tr '\n' ' ' )"
[ "$lens" = "18 " ] \
    && ok "block-scalar and inline descriptions measure identically (18 chars, marker excluded)" \
    || no "measurement disagrees between block-scalar and inline forms: '$lens'"

[ "$fail" -eq 0 ] && echo "skilldescbudgetcheck: ALL PASS" || echo "skilldescbudgetcheck: FAILURES"
exit "$fail"
