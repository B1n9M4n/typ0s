import sys, re, zlib, random
import pyarrow.parquet as pq
parquet, dict_path, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
words = set()
for line in open(dict_path, encoding="utf-8-sig"):
    w = line.rsplit(" ", 1)[0].lower()
    words.add(w)
def dl(a, b):  # Damerau-Levenshtein (optimal string alignment)
    d = [[0]*(len(b)+1) for _ in range(len(a)+1)]
    for i in range(len(a)+1): d[i][0] = i
    for j in range(len(b)+1): d[0][j] = j
    for i in range(1, len(a)+1):
        for j in range(1, len(b)+1):
            c = 0 if a[i-1] == b[j-1] else 1
            d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1]+c)
            if i > 1 and j > 1 and a[i-1] == b[j-2] and a[i-2] == b[j-1]: d[i][j] = min(d[i][j], d[i-2][j-2]+1)
    return d[len(a)][len(b)]
prose = re.compile(r"^[A-Za-z][A-Za-z ,.'’!?;:()\-]{18,240}$")
core = lambda t: re.sub(r"^[^A-Za-z]+|[^A-Za-z']+$", "", t)
seen, keep = set(), {"nonword": [], "realword": []}
for r in pq.read_table(parquet).to_pylist():
    a, b = r["text"].strip(), r["correction"].strip()
    if not prose.match(a) or not prose.match(b) or a == b or (a, b) in seen: continue
    seen.add((a, b))
    ta, tb = a.split(), b.split()
    if len(ta) != len(tb) or len(tb) < 4: continue
    cores = [core(t).lower() for t in tb if core(t)]
    if not cores or sum(c in words for c in cores) / len(cores) < 0.85: continue   # English prose
    diffs = [(x, y) for x, y in zip(ta, tb) if x != y]
    if not 1 <= len(diffs) <= 2: continue
    ok, kinds = True, set()
    for x, y in diffs:
        cx, cy = core(x).lower(), core(y).lower()
        if not cx.isalpha() or not cy.isalpha() or x.replace(core(x), "") != y.replace(core(y), ""): ok = False; break
        if cy not in words or dl(cx, cy) > 2 or len(cy) < 2: ok = False; break
        kinds.add("realword" if cx in words else "nonword")
    if not ok or len(kinds) != 1: continue
    keep[kinds.pop()].append((a, b))
for kind, rows in keep.items():
    random.Random(7).shuffle(rows)
    train = [r for r in rows if zlib.crc32(r[1].encode()) % 2 == 0]
    test = [r for r in rows if zlib.crc32(r[1].encode()) % 2 == 1]
    for name, part in (("train", train), ("test", test)):
        with open(f"{out_dir}/{kind}_{name}.tsv", "w") as f:
            for a, b in part: f.write(f"{a}\t{b}\n")
    print(kind, "total", len(rows), "train", len(train), "test", len(test))
    for a, b in rows[:3]: print("   ", a[:80], "=>", b[:80])
