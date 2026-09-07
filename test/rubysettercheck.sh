#!/usr/bin/env bash
# rubysettercheck.sh — gate for Ruby SETTER methods: `def name=(v)` definitions and `obj.name = v` call sites.
#
# Before the fix, two things were wrong at once, and they compounded:
#   1. `def name=(v)` was never indexed. tree-sitter-ruby names such a method with a (setter) node, and
#      queries/ruby/tags.scm's method pattern accepted only (identifier) and (operator). ActiveSupport 7.2's
#      lib/ carries 23 of them, all invisible.
#   2. `w.name = 3` parses as (assignment left: (call method: (identifier))) — the SAME (call) shape as a read —
#      so the call rule captured a reference to `name`, and the resolver handed it to the GETTER `def name`. A
#      write was recorded as a read of a different method: a false edge, not a floor.
# The fix names the setter `name=` on both sides — the definition from the (setter) node's own text, the call
# site by reading the (assignment left:) parent in ingest — so the two meet by name like every other edge.
#
# Stated floor, pinned below so it stays a decision: a COMPOUND assignment `w.count += 1` reads AND writes
# (`count` then `count=`); one capture carries one name, so it keeps the getter edge only.
#
# Usage:  test/rubysettercheck.sh   |   RIPWIRE_BIN=asan/ripwire test/rubysettercheck.sh
# Exits non-zero on any failure. Does NOT edit test/regression.sh. Self-contained via mktemp.
set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
fail=0
ok(){ echo "  PASS  $1"; }
no(){ echo "  FAIL  $1"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }

DIR="$( mktemp -d )"; trap 'rm -rf "$DIR"' EXIT
FIX="$DIR/fix"; mkdir -p "$FIX"   # the corpus — outputs live in $DIR, never here (the crawl census would count them)

cat > "$FIX/s.rb" <<'RUBY'
class W
  def name
    @name
  end

  def name=(v)
    @name = v
  end

  def count
    @count
  end

  def count=(v)
    @count = v
  end

  def self.limit=(v)
    @limit = v
  end

  def rename(v)
    self.name = v
  end
end

class Other
  def name=(v)
    @n = v
  end
end

def writer(w)
  w.name = 3
end

def reader(w)
  w.name
end

def bumper(w)
  w.count += 1
end
RUBY

MAP="$DIR/map.xml"
"$BIN" "$FIX" --no-cache >"$MAP" 2>"$DIR/map.err"
[ $? -eq 0 ] && ok "default map exits 0" || no "default map exited non-zero: $( cat "$DIR/map.err" )"
[ -s "$DIR/map.err" ] && no "unexpected stderr: $( head -3 "$DIR/map.err" )" || ok "clean stderr"
command -v xmllint >/dev/null 2>&1 && { xmllint --noout "$MAP" && ok "xmllint --noout" || no "xmllint failed"; }

SPLIT="$DIR/split"; sed 's/></>\n</g' "$MAP" >"$SPLIT"
rowOf(){ awk -v pat="$1" '$0 ~ pat{f=1;print;next} /^<s /{f=0} f' "$SPLIT"; }   # the <s> row matching an attribute + its <c> children (top-level defs carry no id=, so pass n="…")

echo "=== setter definitions are indexed, scoped, and distinct from their getters ==="
grep -q '<s t="method" n="name=" id="s.rb::W::name="' "$SPLIT" && ok "def name=(v) → t=\"method\" n=\"name=\" id=\"s.rb::W::name=\"" || no "def name=(v) not indexed as W::name=: $( grep -o 'n="name[^"]*"[^>]*' "$SPLIT" | head -3 | tr '\n' ' ' )"
grep -q 'n="count=" id="s.rb::W::count="' "$SPLIT" && ok "def count=(v) → W::count=" || no "def count=(v) not indexed"
grep -q 'n="limit=" id="s.rb::W::limit="' "$SPLIT" && ok "def self.limit=(v) → W::limit= (singleton setter)" || no "def self.limit=(v) not indexed"
grep -q 'n="name=" id="s.rb::Other::name="' "$SPLIT" && ok "Other#name= indexed separately" || no "Other#name= not indexed"
grep -q '<s t="method" n="name" id="s.rb::W::name"' "$SPLIT" && ok "getter def name still indexed as W::name" || no "getter W::name missing"
[ "$( grep -c 'n="name" ' "$SPLIT" )" -eq 1 ] && ok "exactly one symbol named name (the getter)" || no "expected one getter row, got $( grep -c 'n="name" ' "$SPLIT" )"

echo "=== a setter CALL edges to the setter, never to the getter ==="
WR="$( rowOf 'n="writer" ' )"
echo "$WR" | grep -q '<c n="name="' && ok "writer: w.name = 3 → edge to name=" || no "writer: no edge to name=: $WR"
echo "$WR" | grep -q '<c n="name"/>\|<c n="name" ' && no "writer: w.name = 3 ALSO edges to the getter name (false edge)" || ok "writer: no edge to the getter name"
RD="$( rowOf 'n="reader" ' )"
echo "$RD" | grep -q '<c n="name"' && ok "reader: w.name → edge to the getter name (unchanged)" || no "reader: lost the getter edge: $RD"
echo "$RD" | grep -q '<c n="name="' && no "reader: a plain read edges to name=" || ok "reader: no edge to name="
RN="$( rowOf 'id="s.rb::W::rename"' )"
echo "$RN" | grep -q '<c n="name="' && ok "rename: self.name = v → edge to name=" || no "rename: no edge to name=: $RN"
echo "$RN" | grep -q 'amb=' && no "rename: self.name = v stayed ambiguous between W::name= and Other::name= (Rule 1 should pin the self receiver)" || ok "rename: pinned to W::name= (self receiver, no amb=)"
echo "$RN" | grep -q '<c n="name"/>\|<c n="name" ' && no "rename: self.name = v also edges the getter" || ok "rename: no edge to the getter"

echo "=== stated floor: compound assignment keeps the getter edge only ==="
BP="$( rowOf 'n="bumper" ' )"
echo "$BP" | grep -q '<c n="count"' && ok "bumper: w.count += 1 → edge to count (the read half)" || no "bumper: lost the getter edge: $BP"
echo "$BP" | grep -q '<c n="count="' && no "bumper: w.count += 1 edges count= — the floor moved; update this gate AND the tags.scm header" || ok "bumper: no edge to count= (floor, stated)"

echo "=== verbs address the setter by its own name ==="
CL="$( "$BIN" "$FIX" --no-cache --callers=name= 2>/dev/null )"
echo "$CL" | grep -q 'count="2"' && ok "--callers=name= reports count=2 (writer, rename)" || no "--callers=name= did not report count=2: $( echo "$CL" | grep -o '<callers[^>]*' )"
echo "$CL" | grep -q 'n="writer"' && echo "$CL" | grep -q 'n="rename"' && ok "…listing writer and rename" || no "--callers=name= is missing writer or rename"
CG="$( "$BIN" "$FIX" --no-cache --callers=W::name 2>/dev/null )"
echo "$CG" | grep -q 'n="writer"' && no "--callers=W::name lists writer — a setter call still reaches the getter" || ok "--callers=W::name does not list writer"
echo "$CG" | grep -q 'n="reader"' && ok "--callers=W::name lists reader" || no "--callers=W::name is missing reader: $CG"

echo "=== determinism ==="
"$BIN" "$FIX" --no-cache >"$DIR/b.xml" 2>/dev/null
cmp -s "$MAP" "$DIR/b.xml" && ok "byte-identical across two runs" || no "output differs across runs"

echo "=== mutation: turn the write into a read → the setter edge must vanish (non-tautological) ==="
MUT="$DIR/mut"; mkdir -p "$MUT"
sed 's/  w.name = 3/  w.name/' "$FIX/s.rb" >"$MUT/s.rb"
grep -q '^  w.name$' "$MUT/s.rb" || no "mutation did not apply"
MW="$( "$BIN" "$MUT" --no-cache 2>/dev/null | sed 's/></>\n</g' | awk '/n="writer" /{f=1;print;next} /^<s /{f=0} f' )"
echo "$MW" | grep -q '<c n="name="' && no "mutation: writer still edges name= after the write became a read" || ok "mutation: setter edge gone"
echo "$MW" | grep -q '<c n="name"' && ok "mutation: …and the read now edges the getter" || no "mutation: the read did not edge the getter: $MW"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
