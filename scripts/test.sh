#!/bin/sh
# Runs the BCTask test suite (Swift Testing).
#
# Usage: scripts/test.sh [extra swift-test args]
#
# Toolchain support: on Command Line Tools-only machines (no full Xcode) the
# Swift Testing framework and macro plugin live outside the SDK, and SwiftPM's
# ephemeral test runner must also see them or it compiles `canImport(Testing)`
# false and silently runs zero tests. The workaround below derives paths from
# the ACTIVE developer directory (xcode-select -p) and applies them only for
# CommandLineTools; a full-Xcode developer dir is left untouched.
#
# CLT-only retry policy (see .slim/debug/swift-testing-midrun-exit.md): on CLT
# the SwiftPM test helper can lose the trailing summary line after a normal
# test-process exit (`swift test` exits 0 with no summary). The wrapper
# therefore retries ONLY that shape of run: `swift test` status 0 with no
# test summary, up to 12 attempts total, labeled `CLT transport retry N/12`.
# A nonzero exit status, a zero/nonpassing summary, or a complete summary
# missing a discovery canary fails immediately with no retry. A full-Xcode
# (or unknown) developer dir runs exactly one attempt.
#
# Portability caveat (noted honestly): the full-Xcode path of this script has
# NOT been verified in this environment because only CLT is installed here.
#
# The script refuses to report success unless a uniquely named discovery
# canary ran and the summary clearly reports a passing nonzero test count —
# guarding against the silent zero-test trap of bare `swift test` on
# CLT-only toolchains. Summary detection intentionally precedes canary
# validation: a truncated transport can omit a canary that did run.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

developer_dir="$(xcode-select -p 2>/dev/null || true)"
case "$developer_dir" in
    *CommandLineTools)
        is_clt=1
        max_attempts=12
        frameworks="$developer_dir/Library/Developer/Frameworks"
        plugins="$developer_dir/usr/lib/swift/host/plugins/testing"
        clt_dev_usrlib="$developer_dir/Library/Developer/usr/lib" ;;
    *)
        is_clt=0
        max_attempts=1 ;;
esac

workdir="$(mktemp -d "${TMPDIR:-/tmp}/bctask-test-attempts.XXXXXXXX")"
attempt=0

cleanup() {
    rm -rf "$workdir" 2>/dev/null || true
}

on_signal() {
    echo "FAIL: scripts/test.sh interrupted by signal" >&2
    if [ "$attempt" -gt 0 ] && [ -f "$workdir/attempt-$attempt.log" ]; then
        echo "--- buffered attempt $attempt output ---" >&2
        cat "$workdir/attempt-$attempt.log" >&2
        echo "--- end buffered attempt $attempt output ---" >&2
    else
        echo "no buffered attempt output" >&2
    fi
    cleanup
    exit 1
}
trap on_signal HUP INT TERM
trap cleanup EXIT

while :; do
    attempt=$((attempt + 1))
    attempt_log="$workdir/attempt-$attempt.log"

    # Two direct invocation branches; no word-split flag string, and `"$@"`
    # is preserved exactly as the user passed it.
    if [ "$is_clt" -eq 1 ]; then
        swift test --enable-swift-testing \
            -Xswiftc -F -Xswiftc "$frameworks" \
            -Xswiftc -plugin-path -Xswiftc "$plugins" \
            -Xlinker -rpath -Xlinker "$frameworks" \
            -Xlinker -rpath -Xlinker "$clt_dev_usrlib" \
            "$@" > "$attempt_log" 2>&1
    else
        swift test --enable-swift-testing "$@" > "$attempt_log" 2>&1
    fi
    status=$?
    cat "$attempt_log"

    # (a) Nonzero `swift test` status: real build/test failure — no retry.
    if [ "$status" -ne 0 ]; then
        echo "FAIL: swift test exited with status $status" >&2
        exit "$status"
    fi

    # Summary detection MUST precede canary validation: a truncated transport
    # can omit a canary that genuinely ran.
    summary="$(grep -E 'Test run with [0-9]+ tests? in [0-9]+ suites? ' "$attempt_log" | tail -1)"

    # (b) No summary: the only retryable shape. CLT-only, attempts bounded.
    if [ -z "$summary" ]; then
        if [ "$is_clt" -eq 1 ] && [ "$attempt" -lt "$max_attempts" ]; then
            printf 'CLT transport retry %d/12: no final test summary — assuming transient helper stream loss\n' "$attempt" >&2
            continue
        fi
        echo "FAIL: no 'Test run with N tests' summary found — tests may have silently not run" >&2
        exit 1
    fi

    count="$(printf '%s\n' "$summary" | sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/')"

    # (c) Zero, failed, or otherwise nonpassing summary: fail immediately.
    if [ -z "$count" ] || [ "$count" -lt 1 ]; then
        echo "FAIL: test summary reported zero tests: '$summary'" >&2
        exit 1
    fi
    case "$summary" in
        *" passed"*) ;;
        *)
            echo "FAIL: test summary does not report a passing run: '$summary'" >&2
            exit 1 ;;
    esac

    # (d) Complete passing summary, but a canary is absent: fail immediately.
    for canary in "swiftTestingDiscoveryCanaryRunsMustAppearInSummary" "swiftTestingAppModelDiscoveryCanary"; do
        if ! grep -Fq "$canary" "$attempt_log"; then
            echo "FAIL: discovery canary $canary did not run — Swift Testing did not execute that test target" >&2
            exit 1
        fi
    done

    # (e) Passing nonzero summary with both canaries: success.
    printf 'Canary discovered; %s\n' "$summary"
    exit 0
done
