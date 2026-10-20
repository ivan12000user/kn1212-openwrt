#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# Only runs on an isolated Linux build host. Never contacts the router.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
  echo "Linux x86_64 is required." >&2; exit 1;
}
[[ "$ROOT" != *" "* ]] || { echo "Build path must not contain spaces." >&2; exit 1; }
WORK="$ROOT/work"
OUT="$ROOT/output"
[[ ! -e "$WORK" && ! -e "$OUT" ]] || {
  echo "Use a fresh checkout: work/output already exists." >&2; exit 1;
}
mkdir -p "$WORK" "$OUT/logs" "$OUT/evidence"
exec > >(tee "$OUT/logs/build.log") 2>&1
trap 'echo "Build stopped at line $LINENO. No successful firmware artifact should be published."' ERR

VERSION=25.12.6
PROFILE=keenetic_kn-1212
BASE="https://downloads.openwrt.org/releases/$VERSION/targets/ramips/mt76x8"
IB="openwrt-imagebuilder-$VERSION-ramips-mt76x8.Linux-x86_64"
IB_SHA=7f26c50440cadd83362c444778f80f4a214ee76f3c192ef85ef074f2c56d89ec
AWG="https://slava-shchipunov.github.io/awg-openwrt/$VERSION/ramips/mt76x8"

fetch() {
  curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 30 --max-time 900 "$1" -o "$2"
}
verify() { printf '%s  %s\n' "$1" "$2" | sha256sum --check --strict; }

fetch "$BASE/$IB.tar.zst" "$WORK/$IB.tar.zst"
verify "$IB_SHA" "$WORK/$IB.tar.zst"
fetch "$BASE/profiles.json" "$OUT/evidence/official-profiles.json"
fetch "$BASE/sha256sums" "$OUT/evidence/official-sha256sums"
python3 - "$OUT/evidence/official-profiles.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["version_number"] == "25.12.6"
assert p["target"] == "ramips/mt76x8"
assert p["linux_kernel"]["version"] == "6.12.112"
assert p["linux_kernel"]["vermagic"] == "a846a534ded0ac8aee22713ce7931f3e"
assert "keenetic,kn-1212" in p["profiles"]["keenetic_kn-1212"]["supported_devices"]
PY
tar --zstd -xf "$WORK/$IB.tar.zst" -C "$WORK"
BUILDER="$WORK/$IB"
test -f "$BUILDER/Makefile"
test -f "$BUILDER/repositories"
# Never disable signature or dependency checks.
grep -qx 'CONFIG_SIGNATURE_CHECK=y' "$BUILDER/.config"

# 25.12.6 Image Builder leaves pkg_ver set across foreach iterations.
# Reset the temporary variable before each package; retain all explicit pins.
python3 - "$BUILDER/Makefile" "$OUT/evidence" <<'PY'
from pathlib import Path
import difflib, sys
path = Path(sys.argv[1])
before = path.read_text()
needle = '  $(if $(findstring =,$(pkg)),$(eval pkg_ver:==$(lastword $(subst =, ,$(pkg)))))'
assert before.count(needle) == 1, "Unexpected Image Builder version formatter"
after = before.replace(needle, '  $(eval pkg_ver:=)\n' + needle)
path.write_text(after)
patch = ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                   fromfile='Makefile.original', tofile='Makefile'))
(Path(sys.argv[2]) / 'imagebuilder-version-reset.patch').write_text(patch)
PY

# Trust is scoped to this explicit third-party AWG publisher.
fetch "https://slava-shchipunov.github.io/awg-openwrt/keys/awg-openwrt-feed.pem" \
  "$BUILDER/keys/awg-openwrt-feed.pem"
verify b4517063ef2994e7ea4f9ec21e1a9f8160ed9707a9faebe394919edf862adbe8 \
  "$BUILDER/keys/awg-openwrt-feed.pem"
mkdir -p "$WORK/awg"
fetch "$AWG/packages.adb" "$WORK/awg/packages.adb"
while read -r sha name; do
  fetch "$AWG/$name" "$WORK/awg/$name"
  verify "$sha" "$WORK/awg/$name"
done <<'PACKAGES'
b3a9d5ad6cdfbb89870c78ee515a63690396523b5a5ad1ae3e5d237359c7e376 amneziawg-tools-3.1.20260812-r1.apk
03692f02352567ad5070cba52e272ef1f13f5480079e18e02b40d54337b45380 kmod-amneziawg-6.12.112.3.1.20260906-r1.apk
9d6a3f9c2f2e42a1a7291c50edb7e73f00e49897b9dc88d5ec95847963db3d16 luci-proto-amneziawg-3.1.0-r1.apk
PACKAGES
# APK verifies the publisher's signed index/packages using the added public key.
printf '\nfile://%s/packages.adb\n' "$WORK/awg" >> "$BUILDER/repositories"
cp "$BUILDER/repositories" "$OUT/evidence/build-repositories.txt"
cp "$BUILDER/keys/awg-openwrt-feed.pem" "$OUT/evidence/"
cp "$ROOT/packages.txt" "$OUT/evidence/"

PACKAGES="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$ROOT/packages.txt" | tr '\n' ' ')"
cd "$BUILDER"
make info > "$OUT/evidence/imagebuilder-info.txt"
make image PROFILE="$PROFILE" PACKAGES="$PACKAGES" \
  BIN_DIR="$OUT/images" DISABLED_SERVICES="tailscale"
python3 "$ROOT/scripts/validate.py" "$OUT"

# Cache the exact retrieved packages for inspection and future offline recovery.
# The cache is not advertised as an immediately installable offline repository.
tar -czf "$OUT/package-cache.tar.gz" -C "$BUILDER" dl packages \
  -C "$WORK" awg
cp "$ROOT/README.md" "$OUT/README.md"
cd "$OUT"
find images evidence -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
sha256sum package-cache.tar.gz README.md >> SHA256SUMS
printf '%s\n' 'BUILD PASSED; hardware/modem/Wi-Fi/VPN runtime tests still required.' \
  > BUILD-STATUS.txt
