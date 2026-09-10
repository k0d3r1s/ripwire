#!/usr/bin/env bash
# qualitycrosslangcheck.sh — gate for the §P13.4 cross-language bare-name collision on the api-surface kind.
# canonicalId degrades to the BARE NAME for scope-less free functions (resolve.h), so a module-level Python
# `def add(a,b,c,d)` and a C header `int add(int,int)` share ONE baseline key. computeSnapshot's paramsBySym
# MAX-aggregates over ALL symbols sharing that key (Python side wins: 4), but the delta's now-side used to
# aggregate over the PUBLIC (header-declared) overload set only (C side: 2) — an asymmetry that manufactured
# a phantom `api-surface surface="contract-change" was="4" now="2"` row, and a gating exit 2, on a CLEAN
# tree. The contract this gate pins: a clean working tree IS its own HEAD, so --quality-delta must be
# vacuously exit 0 with regressions="0" — no matter what same-named symbols coexist across languages.
# Usage:  test/qualitycrosslangcheck.sh   |   RIPWIRE_BIN=asan/ripwire test/qualitycrosslangcheck.sh
# Exits non-zero on any failure. Does NOT edit regression.sh. Needs git.
set -u
BIN="${1:-${RIPWIRE_BIN:-./build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$PWD/$BIN"
fail=0
ok(){ echo "  PASS  $1"; }
no(){ echo "  FAIL  $1"; fail=1; }

REPO="$(mktemp -d)"; trap 'rm -rf "$REPO"' EXIT
unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
export GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
cd "$REPO" || exit 1
git init -q --template= || exit 1
HOSTILE_IGNORE="$REPO/.git/global-ignore"
HOSTILE_CONFIG="$REPO/.git/global-gitconfig"
HOSTILE_HOOKS="$REPO/.git/global-hooks"
HOSTILE_FSMONITOR="$REPO/.git/global-fsmonitor"
HOSTILE_FSMONITOR_SENTINEL="$REPO/.git/global-fsmonitor-ran"
HOSTILE_ATTRIBUTES="$REPO/.git/global-attributes"
HOSTILE_FILTER="$REPO/.git/global-filter"
HOSTILE_SIGNER="$REPO/.git/global-signer"
mkdir -p "$HOSTILE_HOOKS" || exit 1
printf '#!/bin/sh\nexit 97\n' > "$HOSTILE_HOOKS/pre-commit" || exit 1
printf '#!/bin/sh\n: > "%s"\nexit 97\n' "$HOSTILE_FSMONITOR_SENTINEL" > "$HOSTILE_FSMONITOR" || exit 1
printf '#!/bin/sh\nexit 97\n' > "$HOSTILE_FILTER" || exit 1
printf '#!/bin/sh\nexit 97\n' > "$HOSTILE_SIGNER" || exit 1
chmod +x "$HOSTILE_HOOKS/pre-commit" "$HOSTILE_FSMONITOR" "$HOSTILE_FILTER" "$HOSTILE_SIGNER" || exit 1
printf 'src/core/\n' > "$HOSTILE_IGNORE" || exit 1
printf '*.cpp filter=hostile\n' > "$HOSTILE_ATTRIBUTES" || exit 1
printf '[core]\n\texcludesFile = %s\n\tattributesFile = %s\n\thooksPath = %s\n\tfsmonitor = %s\n[commit]\n\tgpgSign = true\n[gpg]\n\tprogram = %s\n[filter "hostile"]\n\tclean = %s\n\trequired = true\n' \
  "$HOSTILE_IGNORE" "$HOSTILE_ATTRIBUTES" "$HOSTILE_HOOKS" "$HOSTILE_FSMONITOR" "$HOSTILE_SIGNER" "$HOSTILE_FILTER" > "$HOSTILE_CONFIG" || exit 1
export GIT_CONFIG_GLOBAL="$HOSTILE_CONFIG"
git config --local user.email x@y || exit 1
git config --local user.name x || exit 1
# The hostile global config above makes ignore/attributes/signing/hooks/fsmonitor isolation part of the
# gate rather than an ambient-machine-only repair. The local overrides keep ripwire's own Git subprocess
# isolated too; the empty template prevents executable developer templates from entering the repository.
git config --local core.excludesFile /dev/null || exit 1
git config --local core.attributesFile /dev/null || exit 1
git config --local core.hooksPath /dev/null || exit 1
git config --local core.fsmonitor false || exit 1
git config --local commit.gpgSign false || exit 1
mkdir -p src/core tools
# the collision trio: a 4-param module-level Python `add` (scope-less → bare-name canonId) vs a 2-param
# C `add` declared in a header (the PUBLIC surface) + its non-header definition
printf 'def add(section, cmd, what, opts):\n    return [section, cmd, what, opts]\n' > tools/capture.py
printf 'int add( int a, int b );\nint scale( int v, int k );\n' > src/core/math.h
printf '#include "math.h"\nint add( int a, int b ){ return a + b; }\nint scale( int v, int k ){ return v * k; }\n' > src/core/math.cpp
git add -A || exit 1
git commit -qm init || exit 1
git ls-files --error-unmatch src/core/math.h tools/capture.py >/dev/null 2>&1 || exit 1
[ ! -e "$HOSTILE_FSMONITOR_SENTINEL" ] || { echo "hostile global fsmonitor ran"; exit 1; }

# 1) CLEAN tree (working tree == HEAD) → vacuously no regressions, exit 0, and no api-surface row at all
clean_out="$("$BIN" "$REPO" --quality-delta --no-cache 2>/dev/null)"; clean_rc=$?
[ "$clean_rc" -eq 0 ] \
    && ok "clean tree exits 0 (cross-language same-name symbols present)" \
    || no "clean tree exited $clean_rc (phantom gating regression)"
echo "$clean_out" | grep -q 'regressions="0"' \
    && ok "clean tree reports regressions=\"0\"" \
    || { no "clean tree reports a non-zero regression count"; echo "     got: $(echo "$clean_out" | grep -oE 'regressions="[0-9]+"')"; }
echo "$clean_out" | grep -q 'kind="api-surface"' \
    && { no "clean tree emits a phantom api-surface row"; echo "     got: $(echo "$clean_out" | grep -oE '<r kind="api-surface"[^>]*>')"; } \
    || ok "clean tree emits no api-surface row"

# 2) positive control — the kind still FIRES on a real public-contract arity edit. `scale` has a UNIQUE name
#    (no cross-language mask on its key), so widening it 2→3 params in header+definition must produce a
#    major contract-change row (was=2 now=3) and the gating exit 2.
printf 'int add( int a, int b );\nint scale( int v, int k, int bias );\n' > src/core/math.h
printf '#include "math.h"\nint add( int a, int b ){ return a + b; }\nint scale( int v, int k, int bias ){ return v * k + bias; }\n' > src/core/math.cpp
edit_out="$("$BIN" "$REPO" --quality-delta --no-cache 2>/dev/null)"; edit_rc=$?
echo "$edit_out" | grep -q 'kind="api-surface" sym="scale" was="2" now="3" surface="contract-change"' \
    && ok "real public arity edit still flags api-surface contract-change (was=2 now=3)" \
    || { no "real public arity edit no longer flagged (fix over-suppressed)"; echo "     got: $(echo "$edit_out" | grep -oE '<r kind="api-surface"[^>]*>')"; }
[ "$edit_rc" -eq 2 ] \
    && ok "real contract change still gates (exit 2)" \
    || no "real contract change exited $edit_rc, expected 2"

# 3) determinism on the clean-tree shape
git checkout -q -- src/core/math.h src/core/math.cpp
r1="$("$BIN" "$REPO" --quality-delta --no-cache 2>/dev/null)"; r2="$("$BIN" "$REPO" --quality-delta --no-cache 2>/dev/null)"
[ "$r1" = "$r2" ] && ok "--quality-delta deterministic run-to-run" || no "--quality-delta non-deterministic"
[ ! -e "$HOSTILE_FSMONITOR_SENTINEL" ] || { no "hostile global fsmonitor ran"; exit 1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
