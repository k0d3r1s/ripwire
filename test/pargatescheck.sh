#!/usr/bin/env bash
# pargatescheck.sh — W1-V4 (2026-08-11) gate for test/pargates.py's PER-GATE timeout-budget mechanism.
#
# pargates.py itself is not a *check.sh gate (it's the parallel harness, not a subject under test) so
# nothing in test/regression.sh's own loop ever exercised its logic. That was fine while every gate
# shared one flat 300 s cap — there was no per-gate behaviour to drift — but W1-V4 replaced the flat cap
# with a declared override table (GATE_BUDGET_SEC: gate name -> budget seconds) after cppbenchcheck.sh
# (~856 s) and regexbombcheck.sh (~804 s) were timing out under ASan on a cold cache and being read as
# unhealthy. A table like that CAN drift silently (an entry deleted, a typo in a gate name that makes an
# override a silent no-op, the message format losing the budget number) with nothing catching it. This
# gate is that catch.
#
# Two layers:
#   STATIC  — read test/pargates.py's own source and assert the known-long entries and the default are
#             the declared values, and that the TimeoutExpired message embeds the numeric budget (so a
#             red names its own budget, per the W1-V4 contract).
#   FUNCTIONAL — run the REAL pargates.py logic (not a reimplementation) against a synthetic corpus with
#             one deliberately slow gate, through two throwaway patched copies that only change the
#             NUMBERS (DEFAULT_TIMEOUT_SEC, and one extra GATE_BUDGET_SEC entry) — never the mechanism —
#             so the timeout math and the override lookup are exercised for real, at second-scale instead
#             of the production 300/1200 s values. Proves both that a budget is enforced AND that a
#             per-gate override actually changes the outcome, not just the printed number.
#
# Usage: bash test/pargatescheck.sh   (no ripwire binary needed — this tests test/pargates.py, not the
#                                       binary under test)
set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
PARGATES="$ROOT/test/pargates.py"
fail=0
ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -f "$PARGATES" ] || { echo "no test/pargates.py at $PARGATES"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

echo "pargatescheck: PARGATES=$PARGATES"

# Exercise the real nested executor with controlled jobs, without launching the whole gate suite.
python3 - "$ROOT/test/binoverridecheck.sh" <<'PYJOBS' || fail=1
import concurrent.futures as cf
import os, pathlib, threading, time, sys

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index("results = {}")
end = source.index("\noffenders =", start)
executor = compile(source[start:end], sys.argv[1], "exec")
for configured, expected in ((None, 2), ("1", 1), ("2", 2)):
    if configured is None:
        os.environ.pop("RIPWIRE_BIN_OVERRIDE_JOBS", None)
    else:
        os.environ["RIPWIRE_BIN_OVERRIDE_JOBS"] = configured
    lock = threading.Lock()
    active = peak = 0
    def run_one(g):
        global active, peak
        with lock:
            active += 1
            peak = max(peak, active)
        time.sleep(0.03)
        with lock:
            active -= 1
        return g, 1, "sentinel rejected"
    scope = dict(cf=cf, os=os, sys=sys, run_one=run_one, toRun=range(12))
    exec(executor, scope)
    assert len(scope["results"]) == 12, "nested executor dropped gates"
    assert peak == expected, f"nested workers setting={configured!r}: peak={peak}, expected={expected}"
    print(f"  PASS  nested workers setting={configured!r}: peak={peak}; every gate ran")
for configured in ("", "0", "-1", "invalid"):
    os.environ["RIPWIRE_BIN_OVERRIDE_JOBS"] = configured
    try:
        exec(executor, dict(cf=cf, os=os, sys=sys, run_one=run_one, toRun=range(12)))
    except SystemExit as error:
        assert error.code == "RIPWIRE_BIN_OVERRIDE_JOBS must be a positive integer", str(error)
    else:
        raise AssertionError(f"invalid nested worker setting accepted: {configured!r}")
    print(f"  PASS  invalid nested worker setting rejected: {configured!r}")
PYJOBS

# ── STATIC: the declared budget table has the two W1-V4 entries and the honest default ──────────────────
grep -qE '^DEFAULT_TIMEOUT_SEC = 300$' "$PARGATES" \
    && ok "static: DEFAULT_TIMEOUT_SEC is 300 (the flat cap everything NOT overridden still gets)" \
    || no "static: DEFAULT_TIMEOUT_SEC is not the expected 300 — check for an accidental global raise"

grep -qE '"cppbenchcheck\.sh":\s*1200' "$PARGATES" \
    && ok "static: cppbenchcheck.sh has an honest 1200s budget" \
    || no "static: cppbenchcheck.sh missing (or wrong) from GATE_BUDGET_SEC"

grep -qE '"bodydialectcheck\.sh":\s*900' "$PARGATES" \
    && ok "static: bodydialectcheck.sh has an honest 900s budget (T3 body assembly outgrew the flat cap on plain CI builds)" \
    || no "static: bodydialectcheck.sh missing (or wrong) from GATE_BUDGET_SEC"

grep -qE '"regexbombcheck\.sh":\s*1200' "$PARGATES" \
    && ok "static: regexbombcheck.sh has an honest 1200s budget" \
    || no "static: regexbombcheck.sh missing (or wrong) from GATE_BUDGET_SEC"

# the pre-existing six git-HEAD-build gates must survive the refactor from a flat SLOW_TIMEOUT_SEC set to
# the GATE_BUDGET_SEC dict unchanged — a drift guard, not new behaviour.
for g in crossdirincludecheck nestedimportcheck preproccondcheck pyimportprecisecheck rustimportprecisecheck tsimportprecisecheck; do
    grep -qE "\"${g}\.sh\":\s*900" "$PARGATES" \
        && ok "static: ${g}.sh still budgeted at 900s (git-HEAD-build gates unaffected by the refactor)" \
        || no "static: ${g}.sh lost its 900s override in the GATE_BUDGET_SEC refactor"
done

grep -qE '\{limit\}s' "$PARGATES" \
    && ok "static: the TimeoutExpired message embeds the numeric budget (a red names its own budget)" \
    || no "static: the timeout message no longer includes the declared limit — a red would not name its budget"

# ── FUNCTIONAL: exercise the REAL mechanism at second-scale via two throwaway patched copies ─────────────
# Only DEFAULT_TIMEOUT_SEC (and, in the second copy, one extra dict entry) are rewritten — the timeout
# selection, the subprocess call, and the message formatting are byte-identical to the production script.
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
CORPUSROOT="$TMP/corpus"; mkdir -p "$CORPUSROOT/test"
cat > "$CORPUSROOT/test/probequickgate.sh" <<'EOF'
#!/usr/bin/env bash
sleep 4
echo "probequickgate: slept 4s"
exit 0
EOF
chmod +x "$CORPUSROOT/test/probequickgate.sh"
FAKEBIN="$TMP/fakebin"; printf '#!/usr/bin/env bash\ntrue\n' > "$FAKEBIN"; chmod +x "$FAKEBIN"

patchPargates(){    # patchPargates <outfile> <extra-GATE_BUDGET_SEC-entry-or-empty>
    python3 - "$PARGATES" "$1" "$2" <<'PYEOF'
import sys
src, dst, extra = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
assert "DEFAULT_TIMEOUT_SEC = 300" in text, "DEFAULT_TIMEOUT_SEC = 300 not found verbatim — static check above should already have failed"
text = text.replace("DEFAULT_TIMEOUT_SEC = 300", "DEFAULT_TIMEOUT_SEC = 2", 1)
if extra:
    marker = "GATE_BUDGET_SEC = {"
    assert marker in text, "GATE_BUDGET_SEC = { not found verbatim"
    text = text.replace(marker, marker + "\n    " + extra, 1)
open(dst, "w").write(text)
PYEOF
}

# Copy A: DEFAULT_TIMEOUT_SEC patched to 2s, no override for probequickgate.sh — it must inherit the
# (patched) default and get killed by it, and the printed message must name that exact 2s budget.
COPYA="$TMP/pargates_a.py"
patchPargates "$COPYA" ""
outA="$( python3 "$COPYA" "$CORPUSROOT" "$FAKEBIN" --only probequickgate 2>&1 )"
rcA=$?
echo "$outA" | grep -q 'TIMEOUT after 2s (declared budget=2s)' \
    && ok "functional: a gate with NO override is killed at the (patched) DEFAULT_TIMEOUT_SEC and the message names 2s" \
    || { no "functional: expected 'TIMEOUT after 2s (declared budget=2s)' in output — got:"; echo "$outA" | sed 's/^/    /'; }
[ "$rcA" -ne 0 ] && ok "functional: pargates.py exits non-zero when a gate times out at its declared budget" \
    || no "functional: pargates.py exited 0 despite a timed-out gate (rc=$rcA)"

# Copy B: SAME DEFAULT_TIMEOUT_SEC=2s patch, PLUS a real GATE_BUDGET_SEC override entry for
# probequickgate.sh at 6s. The gate still sleeps 4s — under the override's 6s, over the default's 2s — so
# this proves the override is actually consulted and actually changes the outcome, not just the number in
# a message nobody acts on.
COPYB="$TMP/pargates_b.py"
patchPargates "$COPYB" '"probequickgate.sh": 6,'
outB="$( python3 "$COPYB" "$CORPUSROOT" "$FAKEBIN" --only probequickgate 2>&1 )"
rcB=$?
echo "$outB" | grep -q 'TIMEOUT' \
    && { no "functional: probequickgate.sh timed out even WITH a 6s override (>4s sleep) — override not honored:"; echo "$outB" | sed 's/^/    /'; } \
    || ok "functional: the SAME 4s-sleeping gate, given a 6s override, does NOT time out — GATE_BUDGET_SEC lookup is honored"
[ "$rcB" -eq 0 ] && ok "functional: pargates.py exits 0 once the override covers the gate's real runtime" \
    || no "functional: pargates.py exited $rcB even though the overridden gate should have passed"

# ── F2 (terminality round A, 2026-09-05): a failing gate's report must NAME the arm that failed ─────────
# The summary used to print a failing gate's last 12 non-blank lines. This repo's gates announce a failure
# where it happens (`  FAIL  arm (X) …`) and then keep running their remaining arms, so those last 12 lines
# are a wall of PASS rows plus a closing `SOME CHECKS FAILED` and the one line a reader needs is gone.
# That is not a hypothesis: V1, V2 and the capture-audit close each recorded the same loss for
# `gitstampcheck`, three rounds running, and the failing arm was never identified. Note that printing FEWER
# trailing lines cannot fix it — the fix is SELECTING the failure-carrying lines, and these arms assert the
# selection, the retained full log, and the tail, over the REAL script (no reimplementation).
#
# The fixture is built to be exactly the shape that used to defeat the report: the needle is line 1 and 41
# lines of noise follow it.
cat > "$CORPUSROOT/test/probefaillinegate.sh" <<'EOF'
#!/usr/bin/env bash
echo "  FAIL  arm (Z) NEEDLE-4f2a the line that names the failing arm"
for i in $( seq 1 40 ); do echo "  PASS  filler arm $i"; done
echo "probefaillinegate: SOME CHECKS FAILED"
exit 1
EOF
chmod +x "$CORPUSROOT/test/probefaillinegate.sh"

grep -qE '^FAIL_TAIL_LINES = 5$' "$PARGATES" \
    && ok "static: FAIL_TAIL_LINES is the declared 5 (the tail a failing gate always shows)" \
    || no "static: FAIL_TAIL_LINES is not the declared 5 — the failing-gate report contract moved"

outC="$( python3 "$PARGATES" "$CORPUSROOT" "$FAKEBIN" --only probefaillinegate 2>&1 )"
rcC=$?
echo "$outC" | grep -q 'NEEDLE-4f2a' \
    && ok "functional: the failing arm's own line survives into the report, 41 noise lines below it" \
    || { no "functional: the FAILING ARM'S LINE IS MISSING from the report — the reader is left with the tail only:"; echo "$outC" | sed -n '/FAILURES/,$p' | sed 's/^/    /'; }
echo "$outC" | grep -qE '^ +L[0-9]+: ' \
    && ok "functional: reported lines carry their transcript line number" \
    || no "functional: the report has no L<n>: line numbers — a reader cannot find the line in the full log"
echo "$outC" | grep -q 'probefaillinegate: SOME CHECKS FAILED' \
    && ok "functional: the transcript's last lines are still shown alongside the failure lines" \
    || no "functional: the report dropped the gate's closing lines"
[ "$rcC" -ne 0 ] && ok "functional: pargates.py still exits non-zero for a failing gate" \
    || no "functional: pargates.py exited 0 for a gate that exited 1 (rc=$rcC)"

# the FULL transcript is kept on disk and the report says where — the summary destroys nothing
fullLog="$( echo "$outC" | sed -n 's/.*full output: \(.*\)$/\1/p' | tail -1 )"
if [ -n "${fullLog:-}" ] && [ -f "$fullLog" ]; then
    logLines="$( wc -l <"$fullLog" | tr -d ' ' )"
    if [ "$logLines" -ge 42 ] && grep -q 'NEEDLE-4f2a' "$fullLog" && grep -q 'filler arm 40' "$fullLog"; then
        ok "functional: the failing gate's FULL output ($logLines lines) is retained at the path the report names"
    else
        no "functional: the retained log at $fullLog is not the full transcript ($logLines lines)"
    fi
else
    no "functional: the report names no readable full-output path (got '${fullLog:-}')"
fi

# a gate KILLED at its budget keeps what it printed before the kill — the TIMEOUT line used to be the
# ENTIRE report, so an arm that had already failed at 30 s was invisible at 300 s.
cat > "$CORPUSROOT/test/probeslowfailgate.sh" <<'EOF'
#!/usr/bin/env bash
echo "  FAIL  arm (Y) NEEDLE-9c17 printed before the budget expired"
sleep 5
EOF
chmod +x "$CORPUSROOT/test/probeslowfailgate.sh"
COPYD="$TMP/pargates_d.py"
patchPargates "$COPYD" ""
outD="$( python3 "$COPYD" "$CORPUSROOT" "$FAKEBIN" --only probeslowfailgate 2>&1 )"
echo "$outD" | grep -q 'TIMEOUT after 2s' && echo "$outD" | grep -q 'NEEDLE-9c17' \
    && ok "functional: a gate killed at its budget still reports what it printed before the kill" \
    || { no "functional: the timeout report lost the gate's own pre-kill output:"; echo "$outD" | sed -n '/FAILURES/,$p' | sed 's/^/    /'; }

# ── THE SHARED-TREE TRIPWIRE (2026-09-09, CI run 34298150602) ───────────────────────────────────────────
# pargates.py samples `git status --porcelain` on the checkout while the suite runs and fails the run when
# a gate leaves a NEW untracked/modified path there, naming the gates in flight. Every stamped verb reads
# that same command, from ANY crawl root inside the checkout, for its at="<sha>+dirty" bit, so a writer
# flips every determinism arm running beside it -- tokenbudgetcheck's `--for` arm got est_tokens 3949
# then 3947 while gateexitcheck's probe copy sat in test/gateexitfix/, and the issue thread blamed a
# third gate. Three functional arms on the REAL script (unpatched), each on its own synthetic corpus:
#   WRITER   a git corpus whose one gate holds an untracked file for 1.5 s -> tree_writes=1, the path and
#            the gate named, rc != 0 -- although the gate itself PASSED. The arm that has been seen red.
#   CONTROL  the same gate writing into its own mktemp instead -> tree_writes=0, rc 0. Mutation control:
#            the only difference between the two corpora is where the file lands.
#   UNWATCHED a corpus that is not a git repository -> the tripwire says so (tree_writes=unwatched), and a
#            git-less run is never turned red by a sampler that cannot see anything.
# The sampler is honest about being a sampler: its report calls the list a floor. 1.5 s against a 0.25 s
# poll is six samples of margin, chosen so the WRITER arm cannot flake on a loaded CI runner.
grep -qE 'PARGATES_DIRT_POLL_SEC", "0\.25"' "$PARGATES" \
    && ok "static: the tree tripwire samples every 0.25 s by default (PARGATES_DIRT_POLL_SEC)" \
    || no "static: PARGATES_DIRT_POLL_SEC default is not 0.25 -- the WRITER arm's 1.5 s margin below assumes it"
grep -qE 'sys\.exit\(1 if fails or dirt_seen else 0\)' "$PARGATES" \
    && ok "static: a tree write fails the run (sys.exit reads dirt_seen)" \
    || no "static: the exit status no longer reads dirt_seen -- a writer would be reported but not fail the run"

mkTreeCorpus(){   # mkTreeCorpus <dir> <where-the-gate-writes: checkout|mktemp> [git]
    local d="$1" where="$2" git="${3:-}"
    mkdir -p "$d/test"
    if [ -n "$git" ]; then
        ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t \
          && printf 'base\n' > README.md && git add README.md && git commit -qm base ) >/dev/null 2>&1 \
          || { no "functional(tree): could not init the synthetic git corpus at $d"; return 1; }
    fi
    if [ "$where" = checkout ]; then
        cat > "$d/test/treeprobecheck.sh" <<'EOF'
#!/usr/bin/env bash
fail=0
ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
printf 'probe\n' > "$ROOT/test/tree.probe.tmp"; sleep 1.5; rm -f "$ROOT/test/tree.probe.tmp"
ok "held an untracked file inside the checkout for 1.5 s, then removed it"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES ABOVE"
exit $fail
EOF
    else
        cat > "$d/test/treeprobecheck.sh" <<'EOF'
#!/usr/bin/env bash
fail=0
ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }
T="$( mktemp -d )"; trap 'rm -rf "$T"' EXIT
printf 'probe\n' > "$T/tree.probe.tmp"; sleep 1.5
ok "held a file inside its own mktemp for 1.5 s"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES ABOVE"
exit $fail
EOF
    fi
    chmod +x "$d/test/treeprobecheck.sh"
}

WRITER="$TMP/treewriter";   mkTreeCorpus "$WRITER"   checkout git
CONTROL="$TMP/treecontrol"; mkTreeCorpus "$CONTROL"  mktemp   git
NOGIT="$TMP/treenogit";     mkTreeCorpus "$NOGIT"    checkout

outW="$( python3 "$PARGATES" "$WRITER" "$FAKEBIN" --only treeprobecheck 2>&1 )"; rcW=$?
printf '%s\n' "$outW" | grep -qE '^gates=1 pass=1 .* tree_writes=1$' \
    && ok "functional(tree): WRITER -- the gate passed, and the run still counts tree_writes=1" \
    || { no "functional(tree): WRITER -- expected 'gates=1 pass=1 ... tree_writes=1', got: $( printf '%s\n' "$outW" | grep -E '^gates=' )"; printf '%s\n' "$outW" | sed 's/^/    /' | head -20; }
printf '%s\n' "$outW" | grep -qE '^\*\*\* +\?\? test/tree\.probe\.tmp .*running then: treeprobecheck\.sh' \
    && ok "functional(tree): WRITER -- the report names the path AND the gate in flight when it was seen" \
    || no "functional(tree): WRITER -- the report does not name '?? test/tree.probe.tmp' with 'running then: treeprobecheck.sh'"
printf '%s\n' "$outW" | grep -q 'a floor, not a total' \
    && ok "functional(tree): WRITER -- the report calls its list a floor (a sampler never claims a total)" \
    || no "functional(tree): WRITER -- the report no longer says the list is a floor"
[ "$rcW" -ne 0 ] \
    && ok "functional(tree): WRITER -- a tree write fails the run (rc=$rcW) even though every gate passed" \
    || no "functional(tree): WRITER -- pargates.py exited 0 with a gate writing into the shared checkout"

outC="$( python3 "$PARGATES" "$CONTROL" "$FAKEBIN" --only treeprobecheck 2>&1 )"; rcC=$?
printf '%s\n' "$outC" | grep -qE '^gates=1 pass=1 .* tree_writes=0$' && [ "$rcC" -eq 0 ] \
    && ok "functional(tree): CONTROL -- the same gate writing into its own mktemp: tree_writes=0, rc 0" \
    || no "functional(tree): CONTROL -- expected tree_writes=0 and rc 0, got rc=$rcC: $( printf '%s\n' "$outC" | grep -E '^gates=' )"
printf '%s\n' "$outC" | grep -q 'WROTE INTO THE SHARED CHECKOUT' \
    && no "functional(tree): CONTROL -- a mktemp write was reported as a tree write (false positive)" \
    || ok "functional(tree): CONTROL -- no tree-write report for a gate that never touched the checkout"

outN="$( python3 "$PARGATES" "$NOGIT" "$FAKEBIN" --only treeprobecheck 2>&1 )"; rcN=$?
printf '%s\n' "$outN" | grep -qE '^gates=1 pass=1 .* tree_writes=unwatched$' && [ "$rcN" -eq 0 ] \
    && ok "functional(tree): UNWATCHED -- a non-git corpus reports tree_writes=unwatched and stays rc 0" \
    || no "functional(tree): UNWATCHED -- expected tree_writes=unwatched and rc 0, got rc=$rcN: $( printf '%s\n' "$outN" | grep -E '^gates=' )"
printf '%s\n' "$outN" | grep -q 'tree tripwire: DISARMED' \
    && ok "functional(tree): UNWATCHED -- the run says the tripwire is disarmed rather than implying a clean tree" \
    || no "functional(tree): UNWATCHED -- no DISARMED disclosure on a corpus git cannot see"

[ "$fail" -eq 0 ] && echo "pargatescheck: ALL PASS" || { echo "pargatescheck: SOME CHECKS FAILED"; exit 1; }
