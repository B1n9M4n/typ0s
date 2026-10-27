#!/bin/bash
# One autoresearch experiment: rebuild, retrain both learned models on the FIT split,
# score on the VALIDATION split (Bold mode), then run the safety checks.
# Prints:  SCORE <number>   and   GUARDS PASS | GUARDS FAIL: <why>
set -uo pipefail
cd "$(dirname "$0")/../.."
export TYP0S_DICTIONARY=Dictionary
SRC="FastTypoEngine.swift FixGate.swift RankModel.swift WordModel.swift"
mkdir -p build
build() {
  swiftc -O -module-cache-path build/mc $SRC tools/train/main.swift -o build/train 2>build/compile.log \
    || { echo "COMPILE FAILED"; grep -m5 error build/compile.log; exit 1; }
}
build
build/train learn-rank data/myslips_fit.tsv data/nonword_fit.tsv --out RankModel.swift > build/learn-rank.log 2>&1 || { echo "LEARN-RANK FAILED"; tail -5 build/learn-rank.log; exit 1; }
build
build/train learn data/myslips_fit.tsv data/nonword_fit.tsv --out FixGate.swift > build/learn.log 2>&1 || { echo "LEARN FAILED"; tail -5 build/learn.log; exit 1; }
build
build/train eval data/myslips_val.tsv data/nonword_val.tsv data/realslip_val.tsv --fix bold > build/val.log 2>&1
grep -v objective build/val.log
SCORE=$(grep objective build/val.log | awk '{print $2}')
echo "SCORE $SCORE"

swiftc -O -module-cache-path build/mc $SRC tools/autoresearch/guards/main.swift -o build/guards 2>>build/compile.log || { echo "GUARDS FAIL: guard build"; exit 1; }
TYP0S_FIX=bold build/guards . > build/guards.log 2>&1
reg=$(grep -o 'Regression: [0-9]*/[0-9]*' build/guards.log); gram=$(grep -o 'Grammar: [0-9]*/[0-9]*' build/guards.log)
real=$(grep -o 'Real typos: [0-9]*/' build/guards.log | grep -o '[0-9]*'); clean=$(grep -o 'Clean text: [0-9]* of' build/guards.log | grep -o '[0-9]*' | head -1)
ms=$(grep -o 'avg [0-9.]* ms' build/guards.log | grep -o '[0-9.]*')
why=""
[ "${reg#*: }" = "18/18" ] || why="$why regression ${reg#*: };"
[ "${gram#*: }" = "15/15" ] || why="$why grammar ${gram#*: };"
[ "${clean:-1}" = "0" ] || why="$why clean text changed;"
[ "${real:-0}" -ge 15 ] || why="$why freewriting guard below 15/17;"
awk -v m="${ms:-999}" 'BEGIN { exit !(m < 60) }' || why="$why too slow (${ms} ms/sentence);"
if [ -z "$why" ]; then echo "GUARDS PASS (speed ${ms} ms/sentence)"; else echo "GUARDS FAIL:$why"; fi
