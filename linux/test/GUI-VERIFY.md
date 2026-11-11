# GUI 验证记录（无显示器环境，v1.1-preview）

本文件记录 diskinfer Linux 版 PySide6 工作台在 **WSL2 / Ubuntu 24.04 / 无 X11** 环境下的验证方式与结果，
对应交付要求里的 “GUI 用 `QT_QPA_PLATFORM=offscreen` 启动并截图证明可运行”。

环境：WSL2 Ubuntu 24.04，PySide6 6.12.0（清华镜像安装于 venv），glibc 2.39，引擎基线 llama.cpp fork v0.9.0，
UI 版本 `1.1-preview`。

## 1. 离屏渲染截图（可运行性证据）

```bash
QT_QPA_PLATFORM=offscreen .venv/bin/python gui/workbench.py \
    --screenshot /tmp/gui.png --demo --theme dark --bin-dir build/out/linux-x64
# screenshot: /tmp/gui.png (1470x900) saved=True
```

- 离屏证据：`gui/screenshot-offscreen.png`（由 `test/run-tests.sh` case9 生成）
- 文档截图（`--demo` 数据，offscreen 渲染）：
  `gui/screenshot-chat.png`（简体）、`gui/screenshot-chat-dark.png`（深色）、
  `gui/screenshot-main.png`（指标页）、`gui/screenshot-suite.png`（套件页）、
  `gui/screenshot-chat-en.png`（英文）、`gui/screenshot-chat-zh-hant.png`（繁体）

## 2. `--selftest`（GUI 内置 7 用例套件）

```bash
QT_QPA_PLATFORM=offscreen .venv/bin/python gui/workbench.py --selftest \
    --bin-dir build/out/linux-x64 --model <model.gguf>
```

实测（v1.1-preview，两个模型都 7/7 PASS，exit 0；原始日志 `test/logs/gui-selftest-{dense,moe}.log`）：

| 模型 | 结果 |
|---|---|
| Hai-Test-2.6M（dense F16，5 MiB） | `"passed": 7, "total": 7`（exit 0） |
| Qwen3.5-0.8B-MoE-A0.6B Q4_K_M（513 MiB） | `"passed": 7, "total": 7`（exit 0） |

```
流式 · 小 arena 200 MiB              PASS  token id 序列与 native+-no-extra-bufts 完全一致
原生基线 · STREAM_MB=0 · repack off  PASS
自动 arena (内存/8)                  PASS
关闭 O_DIRECT (buffered)             PASS
disktui --api-only · /v1/models      PASS  新 TUI 无无头单轮模式：起 API 服务，GET /v1/models 200 后退出
llama-completion 流式                PASS
错误路径 (模型不存在)                PASS  按预期非 0 退出 (1)，耗时 0.00 s
```

> native 基线自动加 `-no-extra-bufts`（磁盘流式模式不启用权重重排，同布局才可比，见仓库根 README）。

## 3. `--chat-selftest`（对话模式，真实两轮推理）

```bash
QT_QPA_PLATFORM=offscreen .venv/bin/python gui/workbench.py --chat-selftest \
    --bin-dir build/out/linux-x64 --model <qwen-moe.gguf>
```

实测（`test/logs/gui-chat-selftest.log`，Qwen3.5-0.8B-MoE-A0.6B Q4_K_M）：

```json
{"rc": 0, "ok": true, "messages": 4, "tokens_turn2": 8, "progress_events": 7,
 "layers_seen": [2,4,6,8,11,13,15,17,20,22,23]}
turn1: The capital of France is **Paris**, located in the **Île-de-F…
turn2: The capital of Germany is **Berlin**.
```

说明：`diskc` 常驻引擎、层进度事件、逐 token io/cmp、两轮 KV 前缀处理均工作正常。

## 4. 语法检查

```bash
.venv/bin/python -m py_compile gui/*.py     # 无输出即全部通过（含 gui/i18n.py）
```

## 5. `test/run-tests.sh` 的 GUI 用例（case9）

回归脚本会自动探测 `.venv`/`$HOME/diskinfer-build/venv` 里是否有 PySide6：

- 有 → 跑 `--screenshot` 并检查 PNG 非空 + `py_compile` 全部通过；
- 没有 → SKIP（不影响引擎用例判定）。
