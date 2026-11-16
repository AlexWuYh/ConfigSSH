# ConfigSSH 发布规范

本规范适用于 GitHub Release。**打 tag 前先完成验收并提交对应的 Release Notes**；流水线不会凭提交记录自动编造功能或测试结论。

## 版本与触发

- 仅使用 `vMAJOR.MINOR.PATCH` 格式，例如 `v0.1.0`。Tag 必须指向 `main` 上已提交、已测试的版本；发布流水线会校验 tag 提交是 `origin/main` 的祖先，否则直接失败。
- 将正式文案写入 `.github/release-notes/<tag>.md`，例如 `.github/release-notes/v0.1.0.md`。先运行 `python3 scripts/validate-release-notes.py v0.1.0`。
- 推送 tag 后，`.github/workflows/release.yml` 在 macOS arm64 runner 上运行测试、构建 `.app`、打包 ZIP、生成 SHA-256 校验文件，并上传到对应 GitHub Release。
- `main` 分支和 Pull Request 另由 `.github/workflows/ci.yml` 在 Xcode 27 runner 上验证测试和未签名打包；它不创建 Release。发布 workflow 同样使用 Xcode 27 runner，避免本机与 CI 的主要工具链版本不一致。
- 当前没有 Developer ID 证书与公证凭据。流水线**只创建未签名 prerelease**，资产名称包含 `unsigned`；不能将其描述为已通过 Gatekeeper 的正式下载版。取得签名/公证条件后，先扩充并验收流水线，再调整发布级别与文案。
- 不要把 `.ai/`、真实 `~/.ssh`、私钥、个人服务器地址或测试夹具上传到仓库或 Release 资产。

## Release Notes 版式

以 `.github/RELEASE_NOTES_TEMPLATE.md` 为模板，保持以下顺序和二级标题。面向**用户**描述已验证的变化，不粘贴提交日志；每项用一句动词开头的具体说明，按影响程度排序。

1. `# ConfigSSH vX.Y.Z`：标题必须与 tag 完全一致。
2. `## 本次亮点`：最多三项，说清本版最重要的用户价值。
3. `## 新增`：新功能和入口；没有则写“无”。
4. `## 改进`：现有功能的体验、性能或可访问性变化；没有则写“无”。
5. `## 修复`：可观察的行为修正；不要用“优化若干问题”。
6. `## 安全与隐私`：配置、私钥、加密、权限与数据迁移影响；没有则写“无新增变化”。
7. `## 兼容性与安装`：支持的 macOS/架构、资产名称、安装步骤及**签名状态**。当前必须明确“未签名”。
8. `## 已知限制`：尚未验收或暂不支持的行为与风险，不能省略。
9. `## 校验与来源`：列出随 Release 提供的 `SHA256SUMS.txt`，说明如何校验，并指向仓库中的源码/tag。

禁止 `TODO`、`TBD`、占位符（包括正文中裸露的 `<...>`；代码片段内的尖括号允许）、未经证实的“已完成同步/已登录服务器”等措辞。旧版明文 iCloud 快照不会自动清理，涉及云端配置的版本需说明；未签名包必须说明 Gatekeeper 提示与不可公开分发的现状。不得宣称真实 iCloud 多机、VoiceOver 或终端授权验收已通过，除非有对应记录。

## 发布检查清单

```bash
swift test
swift build -c release
python3 scripts/validate-release-notes.py vX.Y.Z
git diff --check
git ls-files '.ai/**'  # 必须为空
test -z "$(git rev-list --objects --all | grep -E '^[0-9a-f]+ \.ai(/|$)')"  # 可达历史也必须为空
```

确认 Release Notes、版本、截图和源码一致后，再由维护者创建并推送 tag：

```bash
git tag -a vX.Y.Z -m "ConfigSSH vX.Y.Z"
git push origin vX.Y.Z
```

工作流完成后检查 `ConfigSSH-vX.Y.Z-unsigned-macos-arm64.zip` 与 `SHA256SUMS.txt` 均存在，下载并核对校验值，确认 Release 标记为 **Pre-release**。如构建失败，不手动上传来源不明的包；修复后重新运行工作流或使用新的 tag，并记录变更。流水线不会覆盖已上传的资产（不使用 `--clobber`）：若 Release 中已有同名 ZIP，重跑会在上传步骤失败，此时应发布新的 PATCH tag，而不是替换他人可能已下载的文件。
