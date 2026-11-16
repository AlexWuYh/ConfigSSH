#!/usr/bin/env python3
"""Fail a tag build when its user-facing release notes are missing or unfinished."""

from pathlib import Path
import re
import sys


REQUIRED_SECTIONS = (
    "本次亮点",
    "新增",
    "改进",
    "修复",
    "安全与隐私",
    "兼容性与安装",
    "已知限制",
    "校验与来源",
)


def validate(tag: str, root: Path) -> list[str]:
    errors: list[str] = []
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        return ["tag 必须采用 vMAJOR.MINOR.PATCH，例如 v0.1.0"]

    notes_path = root / ".github" / "release-notes" / f"{tag}.md"
    if not notes_path.is_file():
        return [f"缺少 Release Notes：{notes_path}"]
    notes = notes_path.read_text(encoding="utf-8")
    if not notes.startswith(f"# ConfigSSH {tag}\n"):
        errors.append(f"首行必须是 # ConfigSSH {tag}")
    if len(notes.encode("utf-8")) > 40_000:
        errors.append("Release Notes 超过 40 KB，请精简")

    headings = re.findall(r"^## (.+)$", notes, flags=re.MULTILINE)
    if headings != list(REQUIRED_SECTIONS):
        errors.append("二级标题及顺序必须符合 docs/RELEASING.md")
    sections = re.split(r"^## .+$", notes, flags=re.MULTILINE)[1:]
    for title, body in zip(headings, sections):
        if not re.search(r"(?m)^- .{2,}$", body.strip()):
            errors.append(f"“{title}”缺少具体的列表说明")
    if len(sections) >= 1:
        highlights = len(re.findall(r"(?m)^- ", sections[0]))
        if not 1 <= highlights <= 3:
            errors.append("“本次亮点”必须有 1–3 条")
    # Angle brackets are legitimate inside code (`script <tag>`); only bare ones are placeholders.
    prose = re.sub(r"```.*?```|`[^`\n]*`", "", notes, flags=re.DOTALL)
    if re.search(r"(?i)\b(?:TODO|TBD|FIXME)\b|vX\.Y\.Z|待填写|占位符", notes) or re.search(r"<[^>]+>", prose):
        errors.append("Release Notes 包含占位符")
    if "未签名" not in notes or "未公证" not in notes:
        errors.append("当前流水线仅发布未签名预览包，必须明确写出未签名、未公证")
    if "ConfigSSH-" + tag + "-unsigned-macos-arm64.zip" not in notes:
        errors.append("必须写出本 tag 的准确 ZIP 资产名")
    if "SHA256SUMS.txt" not in notes or "shasum -a 256 -c" not in notes:
        errors.append("必须说明 SHA-256 校验文件和校验命令")
    if ".ai/" in notes:
        errors.append("Release Notes 不应引用不公开的 .ai/ 目录")
    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("用法：python3 scripts/validate-release-notes.py vX.Y.Z", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parent.parent
    errors = validate(sys.argv[1], root)
    for error in errors:
        print(f"错误：{error}", file=sys.stderr)
    if errors:
        return 1
    print(f"Release Notes 格式通过：.github/release-notes/{sys.argv[1]}.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
