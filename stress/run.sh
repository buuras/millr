#!/bin/bash
# Stress test: builds two temporary APFS disk images (data + cross-volume target),
# fills A with a synthetic tree, runs `Millr --stress`, profiles it, then detaches
# and deletes everything. User defaults are backed up and restored.
set -uo pipefail
cd "$(dirname "$0")/.."
WORK="${STRESS_WORK:-$TMPDIR/oc-stress}"
OUT="stress/out"
APP="build/Millr.app/Contents/MacOS/Millr"
DOMAIN="io.github.buuras.millr"
mkdir -p "$WORK" "$OUT"

cleanup() {
    hdiutil detach /Volumes/OCStressA -force -quiet 2>/dev/null
    hdiutil detach /Volumes/OCStressB -force -quiet 2>/dev/null
    rm -rf "$WORK"
    rm -rf "$HOME/Library/Caches/Millr/Archives"
    [ -f "$OUT/defaults-backup.plist" ] && defaults import "$DOMAIN" "$OUT/defaults-backup.plist"
}
# Modes: all (default: setup, test, clean) · setup · test [--only a,b] · clean
MODE="${1:-all}"; shift || true
[ "$MODE" = clean ] && { cleanup; exit 0; }
[ "$MODE" = all ] && trap cleanup EXIT

if [ ! -d /Volumes/OCStressA/huge ]; then
    defaults export "$DOMAIN" "$OUT/defaults-backup.plist" 2>/dev/null || true
    echo "== disk görüntüleri"
    hdiutil create -size 8g -fs APFS -type SPARSE -volname OCStressA "$WORK/a.sparseimage" -quiet
    hdiutil create -size 5g -fs APFS -type SPARSE -volname OCStressB "$WORK/b.sparseimage" -quiet
    hdiutil attach "$WORK/a.sparseimage" -nobrowse -quiet
    hdiutil attach "$WORK/b.sparseimage" -nobrowse -quiet
    echo "== veri üretimi"
    /usr/bin/time -p python3 -I stress/gen.py /Volumes/OCStressA
fi
[ "$MODE" = setup ] && exit 0
# Leftovers of an earlier test run on the target volume
rm -rf /Volumes/OCStressB/* /Volumes/OCStressA/{moved,undo,par2} 2>/dev/null

echo "== uygulama"
"$APP" --stress /Volumes/OCStressA /Volumes/OCStressB --hold "$@" > "$OUT/stress.log" 2>&1 &
PID=$!
MAXRSS=0
while kill -0 $PID 2>/dev/null; do
    RSS=$(ps -o rss= -p $PID | tr -d ' ')
    [ -n "$RSS" ] && [ "$RSS" -gt "$MAXRSS" ] && MAXRSS=$RSS
    if grep -q "STRESS DONE" "$OUT/stress.log"; then break; fi
    sleep 0.5
done
echo "INFO  en yüksek RSS $((MAXRSS / 1024)) MB" >> "$OUT/stress.log"

if kill -0 $PID 2>/dev/null; then
    echo "== leaks / vmmap"
    leaks $PID > "$OUT/leaks.txt" 2>&1
    vmmap --summary $PID > "$OUT/vmmap.txt" 2>&1
    kill $PID
fi
cat "$OUT/stress.log"
grep -E "leaks for|total leaked" "$OUT/leaks.txt" | head -3
grep -E "Physical footprint" "$OUT/vmmap.txt"
