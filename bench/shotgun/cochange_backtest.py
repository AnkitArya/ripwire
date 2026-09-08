#!/usr/bin/env python3
"""Backtest of the SHIPPED forgotten-partner check (--situ [3] / cochangePartners): walking history in order,
for each multi-file commit and each file A in it, predict A's partners from PRIOR history only (together>=3,
ranked by deg=together/commits(A), top 8 — the situ rule), and score against the files actually in the commit.
Zimmermann et al. 2004 (Mining Version Histories to Guide Software Changes) is the reference evaluation shape."""
import sys, collections, datetime, statistics
log, cap, top, warm = sys.argv[1], 30, 8, int(sys.argv[2]) if len(sys.argv) > 2 else 150
minDeg = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
commits = []; cur = None
for line in open(log, errors='replace'):
    line = line.rstrip('\n')
    if line.startswith('COMMIT '):
        p = line.split(' ', 3); cur = [datetime.date.fromisoformat(p[2]), []]; commits.append(cur)
    elif line.strip() and cur is not None: cur[1].append(line.strip())
commits = [c for c in reversed(commits) if 1 <= len(c[1]) <= cap]          # oldest first
window = datetime.timedelta(days=548)
pair = collections.Counter(); cnt = collections.Counter(); hist = collections.deque()   # sliding 18-month window
def add(files, sign):
    fs = sorted(set(files))
    for f in fs: cnt[f] += sign
    for i in range(len(fs)):
        for j in range(i+1, len(fs)): pair[(fs[i], fs[j])] += sign
P = []; R = []; anyHit = 0; probes = 0; probesWithPred = 0; single = 0; singleAlarm = 0; singleAlarmHi = 0
for idx, (date, files) in enumerate(commits):
    while hist and hist[0][0] < date - window: add(hist.popleft()[1], -1)
    if idx >= warm:
        fset = set(files)
        for A in fset:
            if cnt[A] < 3: continue
            cands = []
            for B in cnt:
                if B == A: continue
                t = pair[(A, B) if A < B else (B, A)]
                if t >= 3:
                    deg = t / cnt[A]
                    if deg >= minDeg: cands.append((-deg, B))
            cands.sort(); pred = {b for _, b in cands[:top]}
            if len(fset) == 1:
                single += 1
                if pred: singleAlarm += 1
                if any(-d >= 0.5 for d, _ in cands[:top]): singleAlarmHi += 1
                continue
            probes += 1
            if not pred: continue
            probesWithPred += 1
            hit = pred & (fset - {A})
            P.append(len(hit)/len(pred)); R.append(len(hit)/len(fset - {A}))
            if hit: anyHit += 1
    add(files, +1); hist.append((date, files))
print(f"commits(kept, oldest-first)={len(commits)} warmup={warm} minDeg={minDeg} top={top}")
print(f"multi-file probes={probes}  with>=1 predicted partner={probesWithPred} ({100*probesWithPred/max(1,probes):.0f}%)")
print(f"  precision@{top}={statistics.mean(P) if P else 0:.3f}  recall={statistics.mean(R) if R else 0:.3f}  any-hit={100*anyHit/max(1,probesWithPred):.0f}% of predicted probes")
print(f"single-file commits={single}: the check would name a 'forgotten' partner in {singleAlarm} ({100*singleAlarm/max(1,single):.0f}%), one with deg>=0.5 in {singleAlarmHi} ({100*singleAlarmHi/max(1,single):.0f}%)")
