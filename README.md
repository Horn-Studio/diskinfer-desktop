# diskinfer-desktop（Windows / Linux）

在 Windows / Linux 上运行远大于可用内存的 GGUF 模型：权重不 mmap、不整体读入，按计算图节点流进小块内存 arena，用完按 LRU 换出。

## 1.0.1 Windows/Linux 更新内容

- 三端（Android / Windows / Linux）共用同一套引擎与 TUI：模型选择 → 设置页 → 运行页，外加本机 `/v1` API（4000 端口）。
- **极限小 arena**：arena 小于最大张量时自动按行分块/行窗口读取，下限到 8 MiB；实测 Qwen3.5-0.8B-MoE 用 8–16 MiB、Bonsai2 27B 用 16 MiB 都能跑，输出与 2048 MiB arena 逐 token 一致。
- **TUI 设置页**：新增「Prefill 批量」（1..256，默认 4）、内存池 8..2048；底部与运行页显示**常驻 / 峰值 RAM 预估**；新增 `--mem-probe` 可直接打印内存估算。
- **读盘缓存自动策略**：模型 ≤ 可用内存 45% 时用 buffered IO（page cache 吸收重复的整模型扫描，热起来后不再读盘，更快也更省闪存）；放不下时自动 direct IO。
- **修复**：行/视图窗口 pin 计数、O_DIRECT 对齐偏移、窗口提前释放、并发安装竞态、prefill 多 token 的 compact gather 等数值 bug（窗口模式已与基准逐 token 一致）；以及取消显示成错误、设置丢失、语言被 Termux/环境覆盖、模型列表重复、安装布局等交互问题。

## 下载

Releases → **「1.0.1 Windows/Linux」**：
- `diskinfer-windows-1.0.1-win-x64.zip`（Windows 10/11 x64）
- `diskinfer-linux-1.0.1-x64.tar.gz`（Linux x86_64，glibc ≥ 2.35）

## 目录

- `src/llama.cpp-fork/`：三端共用的 llama.cpp fork 源码（v0.9.0 + diskinfer 补丁）
- Windows：`windows/build/build-windows.ps1`、`windows/device/`、`windows/gui/`、`windows/test/`，详见 [windows/README.md](windows/README.md)
- Linux：`linux/`（`build/`、`device/`、`gui/`、`test/`、`install.sh`），详见 [linux/README.md](linux/README.md)

## 构建

```powershell
# Windows x64（VS2022 + CMake）
pwsh -File windows\build\build-windows.ps1
```

```bash
# Linux x86_64
cd linux && bash build/build-linux.sh
```

## 说明

- tiny arena 只省内存、不省 IO：每个 token 仍会顺序扫一遍模型，速度由磁盘读带宽决定。
- tiny 分块模式下 Prefill 批量增大会明显提高计算缓冲（设置页的峰值 RAM 会跟着变），小内存设备建议 1..8。
- Windows 与 Linux 的贪心 token 不保证跨平台逐 token 相同（浮点累加顺序不同），判错请在同一构建内对照。
