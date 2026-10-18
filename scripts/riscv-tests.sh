#!/usr/bin/env bash
# Runs riscv-tests' isa tests on the harness, one `hio cpu boot` each, and
# sums them up per suite.
#
#   scripts/riscv-tests.sh [-t SECONDS] [-o FILE] <isa-dir> [PATTERN...]
#
# <isa-dir> is riscv-tests' `share/riscv-tests/isa` after `make install`.
# PATTERN picks tests by file name (shell glob); the default is the suites
# this core implements, in DEFAULT below. Run it from the repository root,
# where `hio` finds hns/regs.json; HIO picks another hio binary.
#
# A test's status is hio's: 0 passes, 124 is a timeout (-t, default 60 s),
# and another number is the failing test case (TESTNUM) or an error from
# hio. With -o, one line per test goes to FILE. The exit status is 1 when a
# test did not pass.

set -u

DEFAULT="rv64ui-[pv]-* rv64um-[pv]-* rv64ua-[pv]-* rv64uc-[pv]-* rv64uf-[pv]-* rv64ud-[pv]-* rv64mi-p-* rv64si-p-*"

timeout=60
out=""
while getopts "t:o:h" opt; do
    case $opt in
        t) timeout=$OPTARG ;;
        o) out=$OPTARG ;;
        *) sed -n '2,16s/^# \{0,1\}//p' "$0"; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
if [ $# -lt 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 [-t SECONDS] [-o FILE] <riscv-tests isa dir> [PATTERN...]" >&2
    exit 2
fi
dir=$1
shift
patterns=${*:-$DEFAULT}
hio=${HIO:-hio}
if ! "$hio" cpu boot --help 2>/dev/null | grep -q -- --timeout; then
    echo "$hio has no \`cpu boot --timeout\`: build a newer hio from veryl-harness." >&2
    exit 2
fi

tests=()
for p in $patterns; do
    for f in "$dir"/$p; do
        case $f in *.dump) continue ;; esac
        [ -f "$f" ] && tests+=("$f")
    done
done
if [ ${#tests[@]} -eq 0 ]; then
    echo "no test in $dir matches: $patterns" >&2
    exit 2
fi

[ -n "$out" ] && : > "$out"
declare -A pass total
failed=0
for f in "${tests[@]}"; do
    name=$(basename "$f")
    log=$("$hio" cpu boot --timeout "$timeout" "$f" 2>&1 < /dev/null)
    status=$?
    # The suite is the name up to the environment: rv64ui-p, rv64ui-v, ...
    suite=$(echo "$name" | sed -E 's/^(.*-[pv])-.*/\1/')
    total[$suite]=$(( ${total[$suite]:-0} + 1 ))
    case $status in
        0)   line="pass     $name"; pass[$suite]=$(( ${pass[$suite]:-0} + 1 )) ;;
        124) line="timeout  $name"; failed=1 ;;
        *)   why=$(echo "$log" | grep -m1 '^error:' || echo "$log" | grep -v '^  0x\|^ok:' | tail -1)
             line="fail $(printf '%-3s' "$status") $name  $why"
             failed=1 ;;
    esac
    echo "$line"
    [ -n "$out" ] && echo "$line" >> "$out"
done

echo
printf '%-24s %s\n' suite passed
for s in $(printf '%s\n' "${!total[@]}" | sort); do
    printf '%-24s %d/%d\n' "$s" "${pass[$s]:-0}" "${total[$s]}"
done
exit $failed
