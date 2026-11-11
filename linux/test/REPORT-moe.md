# diskinfer Linux x64 test report

Generated: 2026-11-10 08:19:10 (duration 155s)

## Environment

| Item | Value |
|---|---|
| OS | Ubuntu 24.04.4 LTS |
| Kernel | 6.18.33.2-microsoft-standard-WSL2 |
| CPU | Intel(R) Core(TM) i5-14600KF (8 logical cores) |
| Memory | 11961 MiB |
| glibc | 2.39 |
| gcc | gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |
| cmake | cmake version 3.28.3 |
| Binaries | `/mnt/f/diskinfer-linux/build/out/linux-x64` |
| Model | `/mnt/d/LMStudioModel/bayliner1980/Qwen3.5-0.8B-MoE-A0.6B-GGUF/Qwen3.5-0.8B-MoE-A0.6B-Q4_K_M.gguf` (524 MiB, sha256:50edecdb193cadd5…) |
| Source baseline | version: 0.9.0-dev (build 0, commit unknown) (llama.cpp fork v0.9.0) |
| Auto arena expectation | 1495 MiB = MemTotal/8 (clamped 128..2048) |

## Cases

| Case | Name | Status | Checks | Notes |
|---|---|---|---|---|
| preflight | preflight | PASS | 7 | |
| case1 | streaming-200 | PASS | 11 | |
| case2 | native-baseline | PASS | 6 | |
| case3 | auto-arena | PASS | 6 | |
| case4 | odirect-off | PASS | 9 | |
| case5 | disktui-oneshot | PASS | 7 | |
| case6 | error-missing-model | PASS | 3 | |
| case7 | tiny-arena-32 | PASS | 9 | |
| case8 | diskc-json | PASS | 5 | |
| case9 | gui-offscreen | PASS | 4 | |
| case10 | tui-i18n | PASS | 4 | |
| case11 | tui-api | PASS | 5 | |
| compare | cross-case-compare | PASS | 6 | |

## Weight repacking (repack) note

The disk-streaming load path disables the extra buffer types
(`params.use_extra_bufts && !disk_stream` in `src/llama-model.cpp`), so quantized
tensors are not repacked into the platform-specific 8x4/16x1 layout while streaming.
Native mmap runs on AVX2 / ARM-dotprod builds do repack by default, which changes the
float accumulation order and can flip greedy tokens when logits are close.
case2 therefore runs native with `-no-extra-bufts` (same layout as streaming), which
is the correct apples-to-apples baseline; the `case2b` plain-native diagnostic is
only run when a mismatch needs to be classified.

## Key metrics

| Case | exit | runtime | arena | direct io | peak RSS | disk read | tokens | token ids |
|---|---|---|---|---|---|---|---|---|
| case1 | 0 | 27s | 222 MiB (raised to fit the largest tensor) | 1 | 352 MiB | 6881 MiB | 8 | `31586 13 198 32 13 11751 198 33` |
| case2 | 0 | 4s | – MiB (–) | – | 643 MiB | 10 MiB | 8 | `31586 13 198 32 13 11751 198 33` |
| case3 | 0 | 4s | 1495 MiB (auto, 1/8 of ram) | 1 | 644 MiB | 526 MiB | 8 | `31586 13 198 32 13 11751 198 33` |
| case4 | 0 | 27s | 222 MiB (raised to fit the largest tensor) | 0 | 351 MiB | 6859 MiB | 8 | `31586 13 198 32 13 11751 198 33` |
| case7 | 0 | 27s | 222 MiB (raised to fit the largest tensor) | 1 | 351 MiB | 6881 MiB | 8 | `31586 13 198 32 13 11751 198 33` |

## Greedy token-id comparison

Reference: `case2` — `31586 13 198 32 13 11751 198 33`

| Variant | Token ids | vs reference |
|---|---|---|
| case1 | `31586 13 198 32 13 11751 198 33` | identical |
| case2 | `31586 13 198 32 13 11751 198 33` | identical |
| case3 | `31586 13 198 32 13 11751 198 33` | identical |
| case4 | `31586 13 198 32 13 11751 198 33` | identical |
| case7 | `31586 13 198 32 13 11751 198 33` | identical |

## TUI i18n captures

- `test/i18n/tui-en.txt`
- `test/i18n/tui-env-zh-Hant.txt`
- `test/i18n/tui-zh-Hans.txt`
- `test/i18n/tui-zh-Hant.txt`

## Raw logs

- 
- 
- 
- 
- 
- 
- 
- 
- 
- 
- 
- 
- 
- 

## Commands

```
test/run-tests.sh --bin-dir /mnt/f/diskinfer-linux/build/out/linux-x64 --model /mnt/d/LMStudioModel/bayliner1980/Qwen3.5-0.8B-MoE-A0.6B-GGUF/Qwen3.5-0.8B-MoE-A0.6B-Q4_K_M.gguf
```
