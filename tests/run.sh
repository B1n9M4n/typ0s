#!/bin/bash
# typ0s test suite: regression, grammar, your real typos, clean text, speed (Bold mode), plus the Harper grammar step.
set -uo pipefail
cd "$(dirname "$0")/.."
export TYP0S_DICTIONARY=Dictionary
SRC="FastTypoEngine.swift FixGate.swift RankModel.swift WordModel.swift"
mkdir -p build/tests
swiftc -O -module-cache-path build/mc $SRC tools/autoresearch/guards/main.swift -o build/tests/guards || exit 1
swiftc -O -module-cache-path build/mc $SRC HarperGrammar.swift tests/harper/main.swift -o build/tests/harper || exit 1
out=$(TYP0S_FIX=bold build/tests/guards .); echo "$out"
fail=0
echo "$out" | grep -q "Regression: 18/18" || { echo "FAIL regression"; fail=1; }
echo "$out" | grep -q "Grammar: 15/15" || { echo "FAIL grammar"; fail=1; }
echo "$out" | grep -q "Clean text: 0 of" || { echo "FAIL clean text changed"; fail=1; }
real=$(echo "$out" | grep -o 'Real typos: [0-9]*/' | grep -o '[0-9]*'); [ "${real:-0}" -ge 15 ] || { echo "FAIL real typos ${real:-?}/17 (need 15)"; fail=1; }
build/tests/harper || fail=1
[ $fail = 0 ] && echo "ALL TESTS PASS" || echo "TESTS FAILED"
exit $fail
