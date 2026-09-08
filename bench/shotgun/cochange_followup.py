#!/usr/bin/env python3
"""Follow-up measurement: when the forgotten-partner check would ALARM on commit c (a partner B of some file A in c,
deg>=MINDEG, B not in c), is B then touched within the next K commits? A high rate = the alarm names real forgets
(fixed later); a low rate = the alarm names files that simply did not need to change. Also: does the SCATTER of a
commit (files touched) predict a follow-up on one of its partners?"""
import sys, collections, datetime, statistics
log = sys.argv[1]; K = int(sys.argv[2]) if len(sys.argv) > 2 else 3; MINDEG = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
cap, top, warm = 30, 8, 150
commits = []; cur = None
for line in open(log, errors='replace'):
    line = line.rstrip('\n')
    if line.startswith('COMMIT '):
        p = line.split(' ', 3); cur = [datetime.date.fromisoformat(p[2]), []]; commits.append(cur)
    elif line.strip() and cur is not None: cur[1].append(line.strip())
commits = [c for c in reversed(commits) if 1 <= len(c[1]) <= cap]
window = datetime.timedelta(days=548)
pair = collections.Counter(); cnt = collections.Counter(); hist = collections.deque()
def add(files, sign):
    fs = sorted(set(files))
    for f in fs: cnt[f] += sign
    for i in range(len(fs)):
        for j in range(i+1, len(fs)): pair[(fs[i], fs[j])] += sign
alarms = []   # (idx, scatter, alarmedSet)
for idx, (date, files) in enumerate(commits):
    while hist and hist[0][0] < date - window: add(hist.popleft()[1], -1)
    if idx >= warm:
        fset = set(files); named = set()
        for A in fset:
            if cnt[A] < 3: continue
            cands = []
            for B in cnt:
                if B == A or B in fset: continue
                t = pair[(A, B) if A < B else (B, A)]
                if t >= 3 and t / cnt[A] >= MINDEG: cands.append((-t / cnt[A], B))
            cands.sort(); named |= {b for _, b in cands[:top]}
        alarms.append((idx, len(fset), named))
    add(files, +1); hist.append((date, files))
def touchedWithin(idx, B, k):
    return any(B in commits[j][1] for j in range(idx+1, min(len(commits), idx+1+k)))
withAlarm = [a for a in alarms if a[2]]
hitAny = sum(1 for idx, sc, named in withAlarm if any(touchedWithin(idx, B, K) for B in named))
perAlarm = [touchedWithin(idx, B, K) for idx, sc, named in withAlarm for B in named]
# BASELINE: the same question for a random non-touched file with >=3 commits (how often does ANY active file get touched within K?)
import random; random.seed(7)
active = [f for f, c in cnt.items() if c >= 3]
base = []
for idx, sc, named in withAlarm:
    B = random.choice(active); base.append(touchedWithin(idx, B, K))
print(f"K={K} minDeg={MINDEG}: commits scored={len(alarms)} with>=1 alarm={len(withAlarm)} ({100*len(withAlarm)/max(1,len(alarms)):.0f}%)")
print(f"  a named partner IS touched within the next {K} commits: {100*hitAny/max(1,len(withAlarm)):.0f}% of alarmed commits; per named file {100*sum(perAlarm)/max(1,len(perAlarm)):.0f}% (n={len(perAlarm)})")
print(f"  baseline (a random active file touched within {K}): {100*sum(base)/max(1,len(base)):.0f}%")
buckets = [(1,1),(2,3),(4,7),(8,15),(16,30)]
print(f"  by commit SCATTER (files in the commit) -> alarm rate, follow-up rate")
for lo, hi in buckets:
    part = [a for a in alarms if lo <= a[1] <= hi]; pa = [a for a in part if a[2]]
    fu = sum(1 for idx, sc, named in pa if any(touchedWithin(idx, B, K) for B in named))
    if part: print(f"    {lo:2d}-{hi:2d} files: n={len(part):4d} alarmed={100*len(pa)/len(part):3.0f}%  follow-up={100*fu/max(1,len(pa)):3.0f}%")
