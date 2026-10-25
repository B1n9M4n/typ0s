# Makes fast-typing slips in the style seen in the user's freewriting recordings.
import sys, random, re
src, out, seed = sys.argv[1], sys.argv[2], int(sys.argv[3])
rng = random.Random(seed)
rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
pos = {k: (r, c + 0.25 * r) for r, keys in enumerate(rows) for c, k in enumerate(keys)}
def neighbours(c):
    if c not in pos: return []
    return [k for k in pos if k != c and ((pos[k][0]-pos[c][0])**2 + (pos[k][1]-pos[c][1])**2) ** 0.5 <= 1.35]
def bleed(w):            # an extra key next to a letter: bnest, wqhen
    i = rng.randrange(len(w)); n = neighbours(w[i])
    if not n: return w
    j = i if rng.random() < 0.5 else i + 1
    return w[:j] + rng.choice(n) + w[j:]
def missed(w):           # a key that didn't register: thnk (never the apostrophe)
    if len(w) < 4: return w
    i = rng.randrange(1, len(w))
    return w if w[i] == "'" else w[:i] + w[i+1:]
def swap(w):             # two keys in the wrong order: whne
    if len(w) < 3: return w
    i = rng.randrange(len(w) - 1)
    return w if w[i] == w[i+1] or "'" in w[i:i+2] else w[:i] + w[i+1] + w[i] + w[i+2:]
def neighbour(w):        # the key next door: don'y
    i = rng.randrange(len(w)); n = neighbours(w[i])
    return w[:i] + rng.choice(n) + w[i+1:] if n else w
SLIPS = [(bleed, .45), (swap, .15), (neighbour, .13), (missed, .12)]
def slip(w):
    r, acc = rng.random() * .85, 0
    for f, p in SLIPS:
        acc += p
        if r < acc: return f(w)
    return w
out_rows = []
contraction = re.compile(r"\b[a-z]+'(t|s|re|ve|ll|d|m)\b", re.I)
sources = []
for line in open(src, encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 2: continue
    # casual writing is full of contractions; GitHub docs aren't, so give those sentences 3 slip versions
    sources += [parts[1]] * (3 if contraction.search(parts[1]) else 1)
for clean in sources:
    toks = clean.split(" ")
    typed = list(toks)
    i = 0
    while i < len(toks):
        m = re.match(r"^([^A-Za-z]*)([a-z][a-z']*[a-z])([^A-Za-z]*)$", toks[i])
        if m and len(m.group(2)) >= 2 and rng.random() < 0.19:
            pre, w, suf = m.groups()
            if rng.random() < 0.15 and len(w) >= 4:        # space bar slip
                if rng.random() < 0.7 or i + 1 == len(toks) or not re.match(r"^[a-z]+$", toks[i+1]) or suf:
                    k = 1 if rng.random() < 0.5 else len(w) - 1   # "b est" / "anythin g"
                    typed[i] = pre + w[:k] + " " + w[k:] + suf
                else:                                          # "ou tof": space one key early
                    typed[i] = pre + w[:-1]; typed[i+1] = w[-1] + toks[i+1]; i += 1
            else:
                s = slip(w)
                if rng.random() < (0.45 if len(w) >= 5 else 0.15): s = slip(s)   # long words often get two slips (snythinig, idfeasd)
                typed[i] = pre + s + suf
        i += 1
    t = " ".join(typed)
    if t != clean: out_rows.append((t, clean))
with open(out, "w") as f:
    for a, b in out_rows: f.write(f"{a}\t{b}\n")
print(out.split("/")[-1], len(out_rows))
for a, b in out_rows[:4]: print("   ", a[:90])
