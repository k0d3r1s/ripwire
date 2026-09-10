#!/usr/bin/env bash
# RIPWIRE_TEST_DEPS: test/qsnapprefetchcheck.sh,test/redismcpcheck.sh
# Exercise gate failure propagation and isolated CMake argv without modifying a real build tree.
set -euo pipefail
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${RIPWIRE_BIN:-$ROOT/build/ripwire}"
python3 - "$ROOT" "$BIN" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile

root, binary = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).resolve()
failures = []
with tempfile.TemporaryDirectory(prefix="mcpcachegate-") as temporary:
    scratch = pathlib.Path(temporary)
    fake_tools = scratch / "fake tools"; fake_tools.mkdir()
    cmake = fake_tools / "cmake"
    cmake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ["RIPWIRE_GATE_CMAKE_CAPTURE"]).write_text(json.dumps(sys.argv[1:]))
sys.exit(77)
''')
    cmake.chmod(0o755)
    shared = scratch / "shared build"
    private = scratch / "private MCP build with spaces"
    for label, selected, expected in (("default", None, root / "build-tests-redismcp"), ("override", private, private)):
        capture = scratch / (label + ".json")
        env = dict(os.environ, PATH=str(fake_tools) + os.pathsep + os.environ["PATH"],
                   RIPWIRE_TEST_BUILD_DIR=str(shared), RIPWIRE_GATE_CMAKE_CAPTURE=str(capture), RIPWIRE_BIN=str(binary))
        env.pop("RIPWIRE_MCP_TEST_BUILD_DIR", None)
        if selected is not None: env["RIPWIRE_MCP_TEST_BUILD_DIR"] = str(selected)
        result = subprocess.run(["bash", str(root / "test/redismcpcheck.sh")], env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 77 and capture.is_file(), (label, result.returncode, result.stderr)
        args = json.loads(capture.read_text())
        selected_dir = args[args.index("-B") + 1]
        if selected_dir != str(expected):
            failures.append(f"{label}: CMake used {selected_dir!r}, expected isolated {str(expected)!r}")
        else:
            print(f"  PASS  {label}: dedicated MCP build directory survives shared override and path spaces")
    assert not shared.exists() and not private.exists(), "CMake probe modified a real build tree"

    # Only scenario (c)'s suppressed arm uses this threshold. Warnings in (a), (b), or (d) would
    # exercise the parent shell directly and could never reproduce the command-substitution bug.
    wrapper = scratch / "MCP warning wrapper"
    wrapper.write_text('''#!/usr/bin/env bash
if [ "${RIPWIRE_QSNAP_PREFETCH_MIN_FILES:-}" = 999999 ]; then
    printf '%s\\n' 'WARNING: ThreadSanitizer: forced gate self-test' >&2
fi
exec "$RIPWIRE_GATE_REAL_MCP" "$@"
''')
    wrapper.chmod(0o755)
    env = dict(os.environ, RIPWIRE_CACHE_BACKEND="", RIPWIRE_MCP_API_BIN=str(wrapper),
               RIPWIRE_GATE_REAL_MCP=str(binary))
    result = subprocess.run(["bash", str(root / "test/qsnapprefetchcheck.sh"), str(binary)],
                            env=env, capture_output=True, text=True, timeout=180)
    diagnostic = result.stdout + result.stderr
    assert "TSan WARNING in server stderr (c/thr=999999)" in diagnostic, diagnostic
    if result.returncode == 0 or "(c) prefetch-suppressed scenario failed" not in diagnostic:
        failures.append("forced ThreadSanitizer warning inside captured scenario did not fail the gate")
    else:
        print("  PASS  forced ThreadSanitizer warning inside command substitution makes the gate fail")
for failure in failures: print("  FAIL  " + failure)
if failures: sys.exit(1)
print("mcpcachegatecheck: ALL PASS")
PY
