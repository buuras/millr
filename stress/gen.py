"""Synthetic data for the stress test: python3 -I gen.py <root>"""
import os, random, subprocess, sys

root = sys.argv[1]
random.seed(42)
exts = ["txt", "pdf", "jpg", "png", "mov", "swift", "md", "zip", "docx", "xlsx"]
words = ["Çalışma Raporu", "dosya", "Fatura", "İçerik", "görüntü", "Proje Ağacı", "ödev", "Şirket Özeti", "photo", "kayıt"]

def touch(path, size=0):
    with open(path, "wb") as f:
        if size:
            f.write(b"x" * size)

# huge/: one folder, 50k items with mixed, long and Unicode names
huge = os.path.join(root, "huge")
os.makedirs(huge)
for i in range(50_000):
    w = words[i % len(words)]
    if i % 97 == 0:
        name = f"{w} {i} " + "uzun-ad-" * 25
    elif i % 53 == 0:
        name = f"{w} {i} 🚀 émoji"
    else:
        name = f"{w} {i}"
    touch(os.path.join(huge, f"{name}.{exts[i % len(exts)]}"), random.randint(0, 4096) if i % 10 == 0 else 0)
for i in range(200):
    os.makedirs(os.path.join(huge, f"klasör {i}"))

# tree/: 100 × 10 folders × 100 files = 100k files
tree = os.path.join(root, "tree")
for d in range(100):
    for e in range(10):
        p = os.path.join(tree, f"d{d:02d}", f"e{e}")
        os.makedirs(p)
        for f in range(100):
            touch(os.path.join(p, f"f{f}.{exts[f % len(exts)]}"), 512 + f)

# deep/: 60 levels
p = os.path.join(root, "deep")
for lvl in range(60):
    p = os.path.join(p, f"seviye {lvl:02d}")
    os.makedirs(p)
    for k in range(3):
        touch(os.path.join(p, f"not {k}.txt"), 100)

# big/: 4 × 512 MB incompressible files
big = os.path.join(root, "big")
os.makedirs(big)
for i in range(4):
    with open(os.path.join(big, f"b{i}.bin"), "wb") as f:
        for _ in range(32):
            f.write(os.urandom(16 << 20))

os.makedirs(os.path.join(root, "churn"))

# many.zip: 20k entries (tree/d00..d19)
subprocess.run(["/usr/bin/zip", "-qr0", os.path.join(root, "many.zip")] + [f"d{d:02d}" for d in range(20)],
               cwd=tree, check=True)
print("ok")
