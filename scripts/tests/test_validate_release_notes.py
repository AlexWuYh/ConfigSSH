"""Regression tests for the release notes publication gate."""

from pathlib import Path
import importlib.util
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "validate-release-notes.py"
SPEC = importlib.util.spec_from_file_location("validate_release_notes", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="configssh-release-notes-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / ".github" / "release-notes" / "v0.1.0.md"
        self.path.parent.mkdir(parents=True)
        self.path.write_text(
            "# ConfigSSH v0.1.0\n\n"
            + "".join(f"## {section}\n\n- 具体说明用户可验证的变化。\n\n"
                      for section in MODULE.REQUIRED_SECTIONS)
            + "未签名、未公证。ConfigSSH-v0.1.0-unsigned-macos-arm64.zip "
            + "SHA256SUMS.txt shasum -a 256 -c\n",
            encoding="utf-8",
        )

    def test_valid_notes(self) -> None:
        self.assertEqual(MODULE.validate("v0.1.0", self.root), [])

    def test_missing_file_and_invalid_tag(self) -> None:
        self.assertTrue(MODULE.validate("v0.2.0", self.root))
        self.assertTrue(MODULE.validate("release-0.1.0", self.root))

    def test_placeholder_and_missing_unsigned_notice(self) -> None:
        content = self.path.read_text(encoding="utf-8")
        self.path.write_text(content.replace("未签名、未公证", "TODO"), encoding="utf-8")
        errors = MODULE.validate("v0.1.0", self.root)
        self.assertTrue(any("占位符" in error for error in errors))
        self.assertTrue(any("未签名" in error for error in errors))

    def test_angle_brackets_allowed_in_code_but_not_prose(self) -> None:
        content = self.path.read_text(encoding="utf-8")
        self.path.write_text(content + "- 运行 `validate-release-notes.py <tag>` 校验。\n", encoding="utf-8")
        self.assertEqual(MODULE.validate("v0.1.0", self.root), [])
        self.path.write_text(content + "- 新增 <功能名称>。\n", encoding="utf-8")
        self.assertTrue(any("占位符" in error for error in MODULE.validate("v0.1.0", self.root)))

    def test_wrong_title_and_heading_order(self) -> None:
        content = self.path.read_text(encoding="utf-8")
        self.path.write_text(content.replace("# ConfigSSH v0.1.0", "# Wrong Title")
                             .replace("## 新增", "## Added"), encoding="utf-8")
        errors = MODULE.validate("v0.1.0", self.root)
        self.assertTrue(any("首行" in error for error in errors))
        self.assertTrue(any("标题" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
