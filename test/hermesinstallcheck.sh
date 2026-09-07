#!/usr/bin/env bash
# hermesinstallcheck.sh — the Hermes installer target gate.
# Pins that skills/install.sh --hermes and scripts/install.sh's Hermes activation block wire ripwire
# skills into the Hermes agent home exactly like the Claude (~/.claude) / Codex (~/.agents) paths, and
# that each target is hermetic: installing for one agent never touches another agent's home.
# All against TEMP homes + the repo tree, so it is CI-runnable and never touches the real ~/.hermes,
# ~/.claude or ~/.agents.  HERMES_HOME is ALWAYS exported (not just a shell var) so the child
# bash processes inherit the temporary home and can never fall back to the real $HOME/.hermes.
# Usage:  test/hermesinstallcheck.sh
# Exits non-zero on any failure. Does NOT edit regression.sh.
set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
SK="$ROOT/skills"
INSTALL="$ROOT/scripts/install.sh"
fail=0
ok(){ echo "  PASS  $1"; }
no(){ echo "  FAIL  $1"; fail=1; }

[ -f "$SK/install.sh" ] || { echo "no skills/install.sh"; exit 2; }
[ -f "$INSTALL" ] || { echo "no scripts/install.sh"; exit 2; }

TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
export HERMES_HOME="$TMP/hermes-home"; rm -rf "$HERMES_HOME"; mkdir -p "$HERMES_HOME"

shippedAll=$( ls -d "$SK"/ripwire-*/ 2>/dev/null | wc -l | tr -d ' ' )
contributorSkills=$( grep -l '^audience: contributor' "$SK"/ripwire-*/SKILL.md 2>/dev/null | wc -l | tr -d ' ' )
shipped=$(( shippedAll - contributorSkills ))

# helper: the sorted set of user-facing skill NAMES (contributor-only excluded) shipped in the repo
shipped_names() {
    for d in "$SK"/ripwire-*/; do
        [ -d "$d" ] || continue
        name="$( basename "$d" )"
        [ -f "$d/SKILL.md" ] || continue
        grep -q '^audience: contributor' "$d/SKILL.md" 2>/dev/null && continue
        echo "$name"
    done | sort
}

# ---- 1) --hermes installs every user-facing shipped skill under ${HERMES_HOME}/skills ----
bash "$SK/install.sh" --hermes >/dev/null 2>&1
H_FOUND=$( find -L "$HERMES_HOME/skills" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ' )
{ [ "$H_FOUND" -eq "$shipped" ]; } \
    && ok "--hermes exposes all $shipped user-facing shipped skills under HERMES_HOME/skills (found=$H_FOUND)" \
    || no "--hermes exposed $H_FOUND of $shipped skills under HERMES_HOME/skills"

# ---- 1b) the manifest names EXACTLY the linked user-facing set (no contributor-only, nothing omitted) ----
MANIFEST="$HERMES_HOME/skills/.ripwire-manifest-v1"
manifest_set=$( grep '^skill=' "$MANIFEST" 2>/dev/null | sed 's/^skill=//' | sort )
wanted_set=$( shipped_names )
if [ "$manifest_set" != "$wanted_set" ]; then
    no "--hermes manifest set differs from the shipped user-facing set
        (manifest has $(printf '%s\n' "$manifest_set" | wc -l | tr -d ' ') entries, wanted $(printf '%s\n' "$wanted_set" | wc -l | tr -d ' '))"
else
    ok "--hermes manifest declares exactly the linked user-facing set ($(printf '%s\n' "$manifest_set" | wc -l | tr -d ' ') skills)"
fi

# ---- 2) --hermes is hermetic: never touches ~/.claude or the cross-agent ~/.agents ----
FALLBACK_HOME="$TMP/fallback-home"; rm -rf "$FALLBACK_HOME"; mkdir -p "$FALLBACK_HOME"
HOME="$FALLBACK_HOME" bash "$SK/install.sh" --hermes >/dev/null 2>&1   # HERMES_HOME already exported
{ [ ! -e "$FALLBACK_HOME/.claude/skills" ]; } \
    && ok "--hermes does not create a Claude skill home" \
    || no "--hermes also created a Claude skill home"
{ [ ! -e "$FALLBACK_HOME/.agents/skills" ]; } \
    && ok "--hermes does not create the cross-agent ~/.agents skill home" \
    || no "--hermes also created the cross-agent ~/.agents skill home"

# ---- 3) the reverse: default (Claude) and --codex installs never touch a Hermes home ----
CLAUDE_HOME="$TMP/claude-home"; rm -rf "$CLAUDE_HOME"; mkdir -p "$CLAUDE_HOME/.claude"
HOME="$CLAUDE_HOME" bash "$SK/install.sh" >/dev/null 2>&1   # HERMES_HOME still points at TMP
H_AFTER_CLAUDE=$( find -L "$HERMES_HOME/skills" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ' )
{ [ "$H_AFTER_CLAUDE" -eq "$shipped" ]; } \
    && ok "a default (Claude) install leaves the Hermes skill home intact" \
    || no "a default (Claude) install overwrote/pruned the Hermes skill home (found=$H_AFTER_CLAUDE)"

# ---- 4) --hermes re-run is idempotent (0 pruned), proving "safe to re-run" ----
RE_RUN=$( bash "$SK/install.sh" --hermes 2>&1 | grep -c "pruned stale" || true )
{ [ "${RE_RUN:-0}" -eq 0 ]; } \
    && ok "--hermes re-run prunes nothing (idempotent)" \
    || no "--hermes re-run pruned $RE_RUN skills (drift: shipped set changed between runs)"

# ---- 5) --hermes --hook is refused with EXIT STATUS 2 (Hermes has no Claude/Codex hook slot) ----
bash "$SK/install.sh" --hermes --hook >/dev/null 2>&1
HOOK_STATUS=$?
{ [ "$HOOK_STATUS" -eq 2 ]; } \
    && ok "--hermes --hook fails with exit status 2 (hook not supported for the Hermes target)" \
    || no "--hermes --hook exited $HOOK_STATUS, expected 2 — or it succeeded, which is wrong"

[ "$fail" -eq 0 ] && echo "hermesinstallcheck: ALL PASS" || { echo "hermesinstallcheck: FAILURES"; exit 1; }
