# Codex routing check — operator notes (do not give this file to Codex; give it `codex_prompt.md`)

One Codex turn (~5K input tokens, ~2K output) measures how the shortened skill set routes for a real GPT
reader — the one measurement the 2026-09-07 round could not take itself (its raters were Claude models).

## 1. Install the landed skills (no tokens)

    git pull && bash skills/install.sh --codex

Open a fresh Codex session in any repo. Before spending anything, note `codex --version` and whether the
"Skill descriptions were shortened to fit the skills context budget" warning still appears. If it does,
count your non-ripwire skills — they are the remainder of the budget now — or raise
`[skills] max_context_tokens` in `~/.codex/config.toml`.

## 2. The turn (the only tokens spent)

Paste `bench/skillrater/results/2026-09-07/codex_prompt.md` as one message. It carries the instructions and
the 138 held-out prompts (85 with a labelled skill, 53 where no skill should fire); it carries no labels and
no skill descriptions — Codex must route from the catalog it loaded itself. Save the TSV it returns as
`/tmp/answers_codex.tsv`.

## 3. Score (no tokens)

    python3 bench/skillrater/score.py bench/skillrater/results/2026-09-07/keys/key_C2.tsv /tmp/answers_codex.tsv

Prints hit@1 / hit@2 on the 85 positives, false fires on the 53 negatives, and a per-skill won/rows table.
Reference on the same 138 prompts, same key: Opus 85/85, Sonnet 84/85, Fable 84/85, 0 negative fires each.
Within a few rows of that = the shortened set routes the same for Codex. Far below, clustered on one skill in
the per-skill table = that skill's description is the one to fix; the key's id column maps back to the prompt.

## 4. Optional second turn — the comparison the issue reporter actually asked about

Same prompt, pre-round descriptions: `git worktree add /tmp/rw-old c7914e8d`, install from
`/tmp/rw-old/skills/install.sh --codex` (it prunes and relinks), run the turn again, score against
`keys/key_A.tsv` (the 18-skill labels), then re-install from main. That shows whether Codex, unlike the
Claude raters, loses anything to the truncation of the old text. Record both runs in `docs/EVALS.md` under
the round's RESULT.
