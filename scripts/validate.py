"""Fail closed: missing, oversized or incomplete firmware must not be published."""
import hashlib
import json
from pathlib import Path
import sys


def validate(out: Path) -> dict:
    official = json.loads((out / "evidence/official-profiles.json").read_text())
    limit = official["profiles"]["keenetic_kn-1212"]["file_size_limits"]["image"]
    images = out / "images"
    report = {"limit_bytes": limit, "minimum_headroom_bytes": 1048576,
              "hardware_tested": False, "images": []}
    for kind in ("factory", "sysupgrade"):
        found = list(images.glob(f"*keenetic_kn-1212*squashfs-{kind}.bin"))
        if len(found) != 1:
            raise RuntimeError(f"Expected exactly one {kind} image, got {len(found)}")
        image = found[0]
        size = image.stat().st_size
        if not 1_000_000 < size <= limit:
            raise RuntimeError(f"{image.name}: invalid/oversized: {size} > limit {limit}")
        if limit - size < 1048576:
            raise RuntimeError(f"{image.name}: headroom below 1 MiB")
        report["images"].append({
            "file": image.name, "bytes": size, "headroom_bytes": limit - size,
            "sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
        })
    manifests = list(images.glob("*keenetic_kn-1212*.manifest"))
    if len(manifests) != 1:
        raise RuntimeError("Expected one device package manifest")
    installed = {}
    for line in manifests[0].read_text().splitlines():
        fields = line.split()
        if len(fields) >= 2:
            installed[fields[0]] = fields[-1]
    required = {
        "tailscale": "1.104.1-r1",
        "amneziawg-tools": "3.1.20260812-r1",
        "kmod-amneziawg": "6.12.112.3.1.20260906-r1",
        "luci-proto-amneziawg": "3.1.0-r1",
    }
    for name, version in required.items():
        if installed.get(name) != version:
            raise RuntimeError(f"{name}: expected {version}, got {installed.get(name)}")
    for name in ("umbim", "uqmi", "luci-mod-admin-full", "luci-app-firewall",
                 "luci-theme-bootstrap", "uhttpd", "kmod-tun", "kmod-usb-net-cdc-mbim",
                 "kmod-usb-net-qmi-wwan", "comgt-ncm", "kmod-usb-net-rndis"):
        if name not in installed:
            raise RuntimeError(f"Missing required package: {name}")
    for name in ("usbutils", "usbids", "ppp", "ppp-mod-pppoe", "luci-app-package-manager"):
        if name in installed:
            raise RuntimeError(f"Unwanted space-consuming package: {name}")
    report["packages"] = required
    (out / "evidence/validation.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    print(json.dumps(validate(Path(sys.argv[1]).resolve()), indent=2))
