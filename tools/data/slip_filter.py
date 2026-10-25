import sys, re
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if "\t" in l]
pos = {}
for r, keys in enumerate(["qwertyuiop", "asdfghjkl", "zxcvbnm"]):
    for c, k in enumerate(keys): pos[k] = (r, c + 0.25 * r)
adj = lambda a, b: a in pos and b in pos and ((pos[a][0]-pos[b][0])**2 + (pos[a][1]-pos[b][1])**2) ** 0.5 <= 1.35
core = lambda t: re.sub(r"^[^A-Za-z]+|[^A-Za-z']+$", "", t).lower()
def is_slip(x, y):
    if x.startswith(y) or y.startswith(x): return False          # word endings: plural, -ed, -al...
    if len(x) == len(y):
        d = [i for i in range(len(x)) if x[i] != y[i]]
        if len(d) == 1: return adj(x[d[0]], y[d[0]])              # neighbour key
        if len(d) == 2 and d[1] == d[0] + 1: return x[d[0]] == y[d[1]] and x[d[1]] == y[d[0]]   # swapped keys
        return False
    if abs(len(x) - len(y)) == 1:
        long, short = (x, y) if len(x) > len(y) else (y, x)
        for i in range(len(long)):
            if long[:i] + long[i+1:] == short:
                c = long[i]; nb = [long[j] for j in (i-1, i+1) if 0 <= j < len(long)]
                return any(c == n or adj(c, n) for n in nb)       # doubled or bled-in key / dropped one
    return False
kept = []
for a, b in rows:
    diffs = [(core(x), core(y)) for x, y in zip(a.split(), b.split()) if x != y]
    if diffs and all(is_slip(x, y) for x, y in diffs): kept.append((a, b))
with open(sys.argv[2], "w") as f:
    for a, b in kept: f.write(f"{a}\t{b}\n")
print(sys.argv[1].split("/")[-1], len(rows), "->", len(kept))
for a, b in kept[:4]:
    print("   ", [(x, y) for x, y in zip(a.split(), b.split()) if x != y])
