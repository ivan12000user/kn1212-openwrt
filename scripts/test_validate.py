import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("validate", Path(__file__).with_name("validate.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ArtifactGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "images").mkdir()
        (self.root / "evidence").mkdir()
        metadata = {"profiles": {"keenetic_kn-1212": {"file_size_limits": {"image": 15073280}}}}
        (self.root / "evidence/official-profiles.json").write_text(json.dumps(metadata))
        for kind in ("factory", "sysupgrade"):
            (self.root / f"images/test-keenetic_kn-1212-squashfs-{kind}.bin").write_bytes(b"x" * 1000001)
        self.manifest = self.root / "images/test-keenetic_kn-1212.manifest"
        self.manifest.write_text(
            "tailscale - 1.104.1-r1\n"
            "amneziawg-tools - 3.1.20260812-r1\n"
            "kmod-amneziawg - 6.12.112.3.1.20260906-r1\n"
            "luci-proto-amneziawg - 3.1.0-r1\n"
            "umbim - test\nuqmi - test\nluci - test\n"
            "kmod-tun - test\nkmod-usb-net-cdc-mbim - test\n"
        )

    def test_expected_artifact_shape(self):
        self.assertEqual(len(module.validate(self.root)["images"]), 2)

    def test_missing_factory_is_rejected(self):
        (self.root / "images/test-keenetic_kn-1212-squashfs-factory.bin").unlink()
        with self.assertRaisesRegex(RuntimeError, "exactly one factory"):
            module.validate(self.root)

    def test_oversized_image_is_rejected(self):
        image = self.root / "images/test-keenetic_kn-1212-squashfs-factory.bin"
        with image.open("r+b") as stream:
            stream.truncate(15073281)
        with self.assertRaisesRegex(RuntimeError, "oversized"):
            module.validate(self.root)

    def test_wrong_awg_module_is_rejected(self):
        self.manifest.write_text(self.manifest.read_text().replace("6.12.112.3.1", "6.12.94.3.1"))
        with self.assertRaisesRegex(RuntimeError, "kmod-amneziawg"):
            module.validate(self.root)


if __name__ == "__main__":
    unittest.main()
