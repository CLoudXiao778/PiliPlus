# 用 GitHub Actions 构建带渲染补丁的 Windows 版

这个目录里的两个补丁用于验证 PiliPlus 在 Windows 上的视频渲染问题：

- `media_kit_video_windows_render.patch`
  - `mpv_render_context_render` 传入 `MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME = 0`
  - Flutter 纹理回调只在有新视频帧时执行 `CopyResource`（`frame_ready_`）
- `win_x64_github_actions.patch`
  - 在 `win_x64.yml` 里克隆 `bggRGjQaUbCoE/media-kit` 的 `native` 分支
  - 应用上面的补丁
  - 用 `pubspec_overrides.yaml` 把 `media_kit_video` 指向本地打补丁的包
  - 构建完成后把 `libmpv-2.dll` 换成 20261111 构建（含 `1d156861` 和 D3D11 render API）

## 步骤

1. 在 GitHub 上 fork `bggRGjQaUbCoE/PiliPlus`。
2. 克隆你的 fork：

   ```bash
   git clone https://github.com/<你的用户名>/PiliPlus.git
   cd PiliPlus
   ```

3. 把本目录的两个 `.patch` 文件复制到 fork 的 `patches/` 目录（本目录就是 `patches/`）。
4. 应用 workflow 补丁：

   ```bash
   git apply patches/win_x64_github_actions.patch
   ```

   如果因为 fork 不是最新提交而失败，手动把 `win_x64_github_actions.patch` 里的两个 step 加到 `.github/workflows/win_x64.yml` 对应位置即可。

5. 提交并推送：

   ```bash
   git add patches .github/workflows/win_x64.yml
   git commit -m "test: media_kit windows render timing patch"
   git push
   ```

6. 打开 fork 的 **Actions** 页面，启用 workflows，选择 **Build for Windows x64**，点 **Run workflow**。
7. 构建完成后下载 **Windows-file-x64-release**（portable zip）。
8. 解压后运行 `piliplus.exe`。exe 未签名，Windows 可能提示，选择“仍要运行”。

> **重要**：请使用 portable zip。`PiliPlus-Win-Setup` 安装包是在替换 `libmpv-2.dll` 之前生成的，里面仍是旧 DLL；portable zip 里已经是 20261111 的新 DLL。

## 验证

- 在“播放信息”里确认 `hwdec-current` 是 `d3d11va`（或 `d3d11va-copy`）。
- 1080p、1.0x：看 3D 占用、黑帧、卡顿是否改善。
- 再试 1.75x/2x：固定开销会被放大，但补丁应该让帧节奏更稳。
- 如果 3D 仍然接近 99%，且暂停/首页也高，剩余占用主要在 Flutter UI 合成；下一步需要 D3D11 视频输出后端或 UI 侧优化。

## 备注

- 构建机是 `windows-latest`，不需要本地安装 Visual Studio。
- 如果 `git clone` 或 `git apply` 失败，把 Actions 里对应 step 的日志发出来。
- 这个 workflow 只是测试构建，不会修改上游仓库。
