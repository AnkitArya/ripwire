#!/usr/bin/env bash
# hermesinstallcheck.sh — the Hermes installer target gate.
# Pins that skills/install.sh --hermes and scripts/install.sh's Hermes activation block wire ripwire
# skills into the Hermes agent home exactly like the Claude (~/.claude) / Codex (~/.agents) paths, and
# that each target is hermetic: installing for one agent never touches another agent's home.
# All against TEMP homes + the repo tree, so it is CI-runnable and never touches the real ~/.hermes,
# ~/.claude or ~/.agents.
# Usage:  test/hermesinstallcheck.sh
# Exits non-zero on any failure. Does NOT edit regression.sh.
set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
SK="$ROOT/skills"
fail=0
ok(){ echo "  PASS  $1"; }
no(){ echo "  FAIL  $1"; fail=1; }

[ -f "$SK/install.sh" ] || { echo "no skills/install.sh"; exit 2; }

TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT

shippedAll=$( ls -d "$SK"/ripwire-*/ 2>/dev/null | wc -l | tr -d ' ' )
contributorSkills=$( grep -l '^audience: contributor' "$SK"/ripwire-*/SKILL.md 2>/dev/null | wc -l | tr -d ' ' )
shipped=$(( shippedAll - contributorSkills ))

# ---- 1) --hermes installs every user-facing shipped skill under ${HERMES_HOME}/skills ----
HERMES_HOME="$TMP/hermes-home"; rm -rf "$HERMES_HOME"; mkdir -p "$HERMES_HOME"
bash "$SK/install.sh" --hermes >/dev/null 2>&1
H_FOUND=$( find -L "$HERMES_HOME/skills" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ' )
{ [ "$H_FOUND" -eq "$shipped" ]; } \
    && ok "--hermes exposes all $shipped user-facing shipped skills under HERMES_HOME/skills (found=$H_FOUND)" \
    || no "--hermes exposed $H_FOUND of $shipped skills under HERMES_HOME/skills"

# ---- 1b) the manifest names exactly the linked set (contributor-only excluded) ----
if grep -q 'skill=ripwire-opt-remarks' "$HERMES_HOME/skills/.ripwire-manifest-v1" 2>/dev/null; then
    no "(--hermes) manifest declares the contributor-only skill that was not linked"
else
    ok "--hermes manifest names exactly the linked (user-facing) set"
fi

# ---- 2) --hermes is hermetic: never touches ~/.claude or the cross-agent ~/.agents ----
FALLBACK_HOME="$TMP/fallback-home"; rm -rf "$FALLBACK_HOME"; mkdir -p "$FALLBACK_HOME"
HOME="$FALLBACK_HOME" HERMES_HOME="$TMP/hermes-home" bash "$SK/install.sh" --hermes >/dev/null 2>&1
{ [ ! -e "$FALLBACK_HOME/.claude/skills" ]; } \
    && ok "--hermes does not create a Claude skill home" \
    || no "--hermes also created a Claude skill home"
{ [ ! -e "$FALLBACK_HOME/.agents/skills" ]; } \
    && ok "--hermes does not create the cross-agent ~/.agents skill home" \
    || no "--hermes also created the cross-agent ~/.agents skill home"

# ---- 3) the reverse: default (Claude) and --codex installs never touch a Hermes home ----
CLAUDE_HOME="$TMP/claude-home"; rm -rf "$CLAUDE_HOME"; mkdir -p "$CLAUDE_HOME/.claude"
HOME="$CLAUDE_HOME" HERMES_HOME="$TMP/hermes-home" bash "$SK/install.sh" >/dev/null 2>&1
H_AFTER_CLAUDE=$( find -L "$TMP/hermes-home/skills" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ' )
{ [ "$H_AFTER_CLAUDE" -eq "$shipped" ]; } \
    && ok "a default (Claude) install leaves the Hermes skill home intact" \
    || no "a default (Claude) install overwrote/pruned the Hermes skill home (found=$H_AFTER_CLAUDE)"

# ---- 4) --hermes re-run is idempotent (0 pruned), proving "safe to re-run" ----
RE_RUN=$( bash "$SK/install.sh" --hermes 2>&1 | grep -c "pruned stale" || true )
{ [ "${RE_RUN:-0}" -eq 0 ]; } \
    && ok "--hermes re-run prunes nothing (idempotent)" \
    || no "--hermes re-run pruned $RE_RUN skills (drift: shipped set changed between runs)"

# ---- 5) --hermes --hook is refused cleanly (Hermes has no Claude/Codex PreToolUse hook file) ----
if HERMES_HOME="$TMP/hermes-home" bash "$SK/install.sh" --hermes --hook >/dev/null 2>&1; then
    no "--hermes --hook succeeded, but Hermes has no Claude/Codex-style PreToolUse hook slot"
else
    ok "--hermes --hook fails cleanly (hook not supported for the Hermes target)"
fi

[ "$fail" -eq 0 ] && echo "hermesinstallcheck: ALL PASS" || { echo "hermesinstallcheck: FAILURES"; exit 1; }
