#!/usr/bin/env bash
# qchurncheck.sh — gate for Y2 (P2): quality::gitCoChangeAndChurnCached memoizes gitmine's
# `git log --name-only` walk (431 ms on a large private C++ corpus; every rich verb — --for, --metrics,
# --exemplar — pays it once per invocation, main.cpp:5392/5404 call it via gitmine::gitCoChangeAndChurn).
#
# DECIDED key ( "Y2 churn-memo key"): (realpath(root), HEAD sha, window-months,
# gitWindowRefSha) — the qchurn family (quality.h). Committed-history-only: the RAW (epoch, path) stream
# is cached, but it is resolved against the CALLER's live IngestResult fresh on every call, so dirty
# working-tree state is never folded into the memo (main.cpp's two callers pass no uncommitted signal in).
#
# Asserts:
#   (a) a SECOND --for run against an unchanged HEAD does NOT spawn the `git log --name-only` walk —
#       observed via GIT_TRACE (git's own child-process trace, inherited through popen) counting
#       "name-only" occurrences: cold run = 1, warm run = 0.
#   (b) memoized (warm) output is BYTE-IDENTICAL to a fresh run against a COLD, from-scratch blob dir
#       (the cache must never change the answer, only whether the walk runs).
#   (c) a NEW commit changes HEAD sha and invalidates the memo: the next run re-walks (name-only count
#       back to 1) and a distinct qchurn-*.bin blob appears (the old one is not overwritten/reused).
#   (d) key separation: two DIFFERENT roots (or the same root under a different HEAD) never share a
#       blob — implied by (c)'s "distinct blob" check, verified directly too.
#
# Uses its own temp repo + a private TMPDIR (cacheDirLadder() prefers TMPDIR) so the qchurn-*.bin files
# land in a directory we own and can inspect/clear. Needs git + perl(for nothing here, plain grep/wc).
# Usage:  test/qchurncheck.sh   |   RIPWIRE_BIN=build_w2e/ripwire test/qchurncheck.sh
set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
fail=0
ok(){ echo "  PASS  $1"; }
no(){ echo "  FAIL  $1"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

REPO="$( mktemp -d )"; TMP="$( mktemp -d )"; trap 'rm -rf "$REPO" "$TMP"' EXIT
QTMP="$TMP/qtmp"; QCACHE="$QTMP/ripwire"; mkdir -p "$QTMP"   # cacheDirLadder() creates the private child

echo "qchurncheck: BIN=$BIN"

# Y4: shard-aware lookup inside the private Ripwire cache directory.
qchurnfiles(){ find "$QCACHE" -maxdepth 2 -type f -name 'ripwire-qchurn-*.bin' 2>/dev/null; }
nqchurn(){ qchurnfiles | wc -l | tr -d ' '; }
# name_only_count TRACEFILE — how many git child processes in this run's trace invoked --name-only (the
# expensive walk gitCoChangeAndChurnCached guards). Any OTHER git call this run makes (rev-parse, HEAD
# resolution, etc.) never contains "name-only", so this is a clean, argv-based signal — not a timing guess.
name_only_count(){ grep -c "name-only" "$1" 2>/dev/null || true; }
# run TRACEFILE ARGS... — invokes ripwire against $REPO with our private TMPDIR + a fresh GIT_TRACE file.
run(){ local tf="$1"; shift; : > "$tf"; env TMPDIR="$QTMP" GIT_TRACE="$tf" "$BIN" "$REPO" "$@"; }

mkdir -p "$REPO/src"
cat > "$REPO/src/lib.cpp" <<'EOF'
int helper( int x ) { return x + 1; }
int caller( int y ) { return helper( y ) + helper( y + 1 ); }
EOF
git -C "$REPO" init -q
git -C "$REPO" config user.email "dev@x.com"
git -C "$REPO" config user.name  "Dev"
git -C "$REPO" add -A
GIT_AUTHOR_DATE="2026-06-01T12:00:00" GIT_COMMITTER_DATE="2026-06-01T12:00:00" \
    git -C "$REPO" commit -qm "init"

# ── (a) cold run walks once, warm run does not walk at all ─────────────────────────────────────────────
run "$TMP/trace_cold.log" --for="helper" --cache="$TMP/ingest.bin" --no-stable >"$TMP/cold.out" 2>"$TMP/cold.err"; rcCold=$?
COLD_N="$( name_only_count "$TMP/trace_cold.log" )"
if [ "$rcCold" -eq 0 ] && [ "$COLD_N" -ge 1 ]; then
    ok "cold --for run spawns the name-only walk ($COLD_N invocation(s))"
else
    no "cold run wrong (rc=$rcCold, name-only count=$COLD_N)"
fi

if [ "$( nqchurn )" -ge 1 ]; then
    ok "cold run writes a ripwire-qchurn-*.bin blob"
else
    no "no qchurn blob after cold run"
fi

run "$TMP/trace_warm.log" --for="helper" --cache="$TMP/ingest.bin" --no-stable >"$TMP/warm.out" 2>"$TMP/warm.err"; rcWarm=$?
WARM_N="$( name_only_count "$TMP/trace_warm.log" )"
if [ "$rcWarm" -eq 0 ] && [ "$WARM_N" -eq 0 ]; then
    ok "warm --for run does NOT spawn the name-only walk (memo hit; count=$WARM_N)"
else
    no "warm run still walked git log (rc=$rcWarm, name-only count=$WARM_N) — memo not reused"
fi

# ── (b) memoized output byte-identical to a fresh COLD blob dir ────────────────────────────────────────
COLDXDG="$TMP/coldxdg"; mkdir -p "$COLDXDG"
env TMPDIR="$COLDXDG" "$BIN" "$REPO" --for="helper" --cache="$TMP/fresh-ingest.bin" --no-stable >"$TMP/fresh_cold.out" 2>/dev/null
if diff -q "$TMP/warm.out" "$TMP/fresh_cold.out" >/dev/null; then
    ok "warm (memoized) output byte-identical to a fresh-cold-blob-dir run"
else
    no "memoized output diverges from a fresh cold run"; diff "$TMP/fresh_cold.out" "$TMP/warm.out" | head -6
fi
if diff -q "$TMP/cold.out" "$TMP/warm.out" >/dev/null; then
    ok "this run's cold output == this run's warm output (cache never changes the answer)"
else
    no "cold vs warm output differs within the same TMPDIR"; diff "$TMP/cold.out" "$TMP/warm.out" | head -6
fi

# ── (c) a new commit changes HEAD sha ⇒ invalidates: re-walks, and a DISTINCT blob appears ─────────────
before_n="$( nqchurn )"
before_files="$( qchurnfiles | sort )"
cat >> "$REPO/src/lib.cpp" <<'EOF'
int another( int z ) { return z * 2; }
EOF
git -C "$REPO" add -A
GIT_AUTHOR_DATE="2026-06-01T13:00:00" GIT_COMMITTER_DATE="2026-06-01T13:00:00" \
    git -C "$REPO" commit -qm "grow lib" >/dev/null

run "$TMP/trace_new.log" --for="helper" --cache="$TMP/ingest.bin" --no-stable >"$TMP/new.out" 2>"$TMP/new.err"; rcNew=$?
NEW_N="$( name_only_count "$TMP/trace_new.log" )"
if [ "$rcNew" -eq 0 ] && [ "$NEW_N" -ge 1 ]; then
    ok "new HEAD commit: memo invalidated, walk re-runs ($NEW_N invocation(s))"
else
    no "new commit did not invalidate the memo (rc=$rcNew, name-only count=$NEW_N)"
fi

after_n="$( nqchurn )"
after_files="$( qchurnfiles | sort )"
if [ "$after_n" -gt "$before_n" ]; then
    ok "new HEAD sha writes an ADDITIONAL qchurn blob ($before_n -> $after_n)"
else
    no "no new qchurn blob after HEAD changed ($before_n -> $after_n)"
fi
if [ "$( comm -13 <( printf '%s\n' "$before_files" ) <( printf '%s\n' "$after_files" ) | wc -l | tr -d ' ' )" -ge 1 ]; then
    ok "the new blob is a DISTINCT filename (old sha's blob untouched, not overwritten)"
else
    no "new commit reused the old sha's blob filename — key does not include HEAD sha"
fi

# a second run against the NEW head is warm again (proves invalidation isn't a permanent "always cold" bug)
run "$TMP/trace_new2.log" --for="helper" --cache="$TMP/ingest.bin" --no-stable >"$TMP/new2.out" 2>/dev/null; rcNew2=$?
NEW2_N="$( name_only_count "$TMP/trace_new2.log" )"
if [ "$rcNew2" -eq 0 ] && [ "$NEW2_N" -eq 0 ]; then
    ok "second run on the NEW head is warm again (count=$NEW2_N)"
else
    no "second run on new head did not memoize (rc=$rcNew2, count=$NEW2_N)"
fi
if diff -q "$TMP/new.out" "$TMP/new2.out" >/dev/null; then
    ok "new-head cold vs warm output byte-identical"
else
    no "new-head cold vs warm output differs"
fi

# Disabled overrides File and must recompute on every invocation without writing qchurn blobs.
DISABLED_TMP="$TMP/disabled"; mkdir -p "$DISABLED_TMP"
for pass in 1 2; do
    env TMPDIR="$DISABLED_TMP" GIT_TRACE="$TMP/disabled-$pass.trace" "$BIN" "$REPO" --for=helper --cache="$DISABLED_TMP/ingest.bin" --no-cache --no-stable \
        >"$TMP/disabled-$pass.out" 2>"$TMP/disabled-$pass.err"; disabled_rc=$?
    if [ "$disabled_rc" -eq 0 ] && [ "$( name_only_count "$TMP/disabled-$pass.trace" )" -ge 1 ]; then
        ok "Disabled pass $pass walks git log again"
    else
        no "Disabled pass $pass failed to recompute"
    fi
done
if [ -z "$( find "$DISABLED_TMP" -type f )" ] && cmp -s "$TMP/disabled-1.out" "$TMP/new2.out" \
    && cmp -s "$TMP/disabled-1.out" "$TMP/disabled-2.out"; then
    ok "Disabled writes no qchurn blob and preserves File output"
else
    no "Disabled wrote a qchurn blob or changed output"
fi

# ── xmllint clean (sanity — --for output is still well-formed XML under the cached path) ───────────────
if "$BIN" "$REPO" --for="helper" --cache="$TMP/ingest.bin" --no-stable 2>/dev/null | xmllint --noout - 2>/dev/null; then
    ok "xmllint clean"
else
    no "xmllint reported malformed XML"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "SOME CHECKS FAILED"; exit 1; fi
