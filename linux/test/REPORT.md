# diskinfer Linux x64 test report

Generated: 2026-11-10 08:16:30 (duration 17s)

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
| Model | `/mnt/d/LMStudioModel/Horn-Studio/Hai-Test-2.6M/Hai-Test-2.6M.gguf` (5 MiB, sha256:d7bde3684734a3a7…) |
| Source baseline | version: 0.9.0-dev (build 0, commit unknown) (llama.cpp fork v0.9.0) |
| Auto arena expectation | 1495 MiB = MemTotal/8 (clamped 128..2048) |

## Cases

| Case | Name | Status | Checks | Notes |
|---|---|---|---|---|
| preflight | preflight | PASS | 7 | |
| case1 | streaming-200 | PASS | 8 | |
| case2 | native-baseline | PASS | 6 | |
| case3 | auto-arena | PASS | 6 | |
| case4 | odirect-off | PASS | 8 | |
| case5 | disktui-oneshot | PASS | 7 | |
| case6 | error-missing-model | PASS | 3 | |
| case7 | tiny-arena-32 | PASS | 7 | |
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
| case1 | 0 | 0s | 200 MiB (requested) | 1 | 15 MiB | 2 MiB | 2 | `269 17` |
| case2 | 0 | 0s | – MiB (–) | – | 16 MiB | 0 MiB | 2 | `269 17` |
| case3 | 0 | 1s | 1495 MiB (auto, 1/8 of ram) | 1 | 16 MiB | 3 MiB | 2 | `269 17` |
| case4 | 0 | 0s | 200 MiB (requested) | 0 | 15 MiB | 3 MiB | 2 | `269 17` |
| case7 | 0 | 0s | 128 MiB (128 MiB floor) | 1 | 16 MiB | 3 MiB | 2 | `269 17` |

## Greedy token-id comparison

Reference: `case2` — `269 17`

| Variant | Token ids | vs reference |
|---|---|---|
| case1 | `269 17` | identical |
| case2 | `269 17` | identical |
| case3 | `269 17` | identical |
| case4 | `269 17` | identical |
| case7 | `269 17` | identical |

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
test/run-tests.sh --bin-dir /mnt/f/diskinfer-linux/build/out/linux-x64 --model /mnt/d/LMStudioModel/Horn-Studio/Hai-Test-2.6M/Hai-Test-2.6M.gguf
```
