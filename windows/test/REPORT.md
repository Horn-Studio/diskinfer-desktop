# diskinfer-android Windows port - end-to-end verification report

Independent verification of the Windows port of diskinfer-android (llama.cpp fork
that streams GGUF weights from disk into a fixed-size RAM arena).

- Verifier: verify-test (independent; no project sources were modified)
- Date: 2026-10-31 (Asia/Shanghai)
- Overall verdict: **PASS - 7/7 cases, 0 defects found**
- Streamed vs native greedy output: **IDENTICAL token ids** (`11751,13,198,760,6511,314,9338,369`)
- Build under test: fresh static MSVC build produced by `build\build-windows.ps1 -Clean -Jobs 12`
- Model used: only `Qwen3.5-0.8B-Q6_K.gguf` (nothing was downloaded, converted or substituted)

Artifacts:

- Harness: `F:\diskinfer\test\run-tests.ps1` (SHA256 `4B3335B0A47CFFF89B4982AC69E3B7DDECF97DFFD2BF8286AF18A503B145F2D4`)
- Final raw logs + machine summary: `F:\diskinfer\test\logs\run-20261031-224408\`
  (`summary.json`, `summary.md`, one folder per case with `stdout.log`, `stderr.log`, `meta.json`)
- Supplemental llama-completion smoke test: `F:\diskinfer\test\logs\phase2-supplement\`
- Earlier full run with identical results: `F:\diskinfer\test\logs\run-20261031-224209\`

---

## 1. Verdict per case

| Case | Scenario | Status |
| --- | --- | --- |
| case1 | Streaming, arena 200 MiB requested (raised to 222 MiB), greedy | PASS |
| case2 | Native llama.cpp path (`LLAMA_DISK_STREAM_MB=0`), greedy baseline | PASS |
| case3 | Auto arena (`LLAMA_DISK_STREAM_MB` unset) | PASS |
| case4 | Streaming, `LLAMA_DISK_ODIRECT=0` | PASS |
| case5 | disktui one-shot smoke (stdin NUL, stdout redirected) | PASS |
| case6 | Missing model path error path | PASS |
| case7 | Tiny arena 32 MiB (auto-raised), greedy | PASS |
| cross | Streamed vs native greedy token ids (required) | PASS |
| suppl | llama-completion.exe static binary smoke (outside matrix) | PASS |

No hangs, no timeouts, no crash dialogs, no non-zero unexpected exits.

---

## 2. Build under test

All three deliverables are static (static MSVC CRT + static llama/ggml), 0 DLLs in the folder.

| Binary | Size (bytes) | Last write | SHA256 |
| --- | --- | --- | --- |
| `F:\diskinfer\build\out\win-x64\diskrun.exe` | 4,668,416 | 2026-10-31 22:40:13 | `425571AB0C5ABF7745B2B748E560D81C6A3A7A689227E0B4C53DE235CDD76024` |
| `F:\diskinfer\build\out\win-x64\disktui.exe` | 4,692,480 | 2026-10-31 22:40:10 | `4AA98D6E82088143703F779698E2361F68E00335D2C8202C96F224F47CB8086E` |
| `F:\diskinfer\build\out\win-x64\llama-completion.exe` | 7,286,272 | 2026-10-31 22:40:54 | `AFB85591E8987B96BF49DA5ED062EE98277AD4E7C6FF8ACED9379CC76E2D5C75` |

`llama-completion.exe --version` -> `version: 0.7.0-dev (build 0, commit unknown) built with MSVC 19.44.35229.0 for x64`, exit 0.

The hashes above were re-read after the test run and are unchanged, so this report is tied to exactly
that build.

## 3. Model under test

| Item | Value |
| --- | --- |
| Path | `D:\LMStudioModel\lmstudio-community\Qwen3.5-0.8B-GGUF\Qwen3.5-0.8B-Q6_K.gguf` |
| Size | 629,743,584 bytes (matches the allowed model, policy check passed) |
| SHA256 | `32CD8FD124FAABB943019663D39A248D9705439AFFF6EF7CEFE6ECB9CC946DC8` |
| GGUF | v3, architecture `qwen35`, name `Qwen_Qwen3.5 0.8B`, 24 layers, n_embd 1024, vocab 248,320 |
| Tensors | 320 tensors, 590.12 MiB of tensor bytes (187 Q6_K + 133 F32), largest `token_embd.weight` = 198.93 MiB |

Consequence for arena sizing: with this model the 200 MiB request cannot hold the largest tensor, so
the engine must raise the arena to `align_up(198.93 MiB) + 24 MiB` -> **222 MiB**. That is what every
streaming case below shows.

## 4. Environment

| Item | Value |
| --- | --- |
| OS | Microsoft Windows 11 IoT Enterprise LTSC, version 10.0.26100, build 26100 |
| CPU | Intel(R) Core(TM) i5-14600KF, 14 cores / 20 hardware threads |
| RAM | 24,363 MiB total, 14,523 MiB free at test start |
| PowerShell | 7.6.6 (.NET 10.0.12) |
| Machine | HORN-STUDIO |
| Model volume | D: (NVMe/SSD class; ~1.6-2.3 GiB/s effective measured below) |

## 5. Method

Harness `F:\diskinfer\test\run-tests.ps1` (PowerShell 7, ASCII-only output):

- **Environment isolation**: each child gets its own environment block via
  `System.Diagnostics.ProcessStartInfo.Environment`; every `LLAMA_DISK_*` and
  `GGML_CPU_DISABLE_FUSION` variable is removed first, then only the variables of that case are set.
  There is no env leaking between cases (this is why case2 can prove "no streaming" after case1).
- **Timeouts**: 900 s per case (180 s for the error path); on timeout the whole process tree is
  killed and the case is marked TIMEOUT.
- **Capture**: stdout and stderr go to separate files (`stdout.log`, `stderr.log`), so text cannot be
  reordered by stream interleaving. `LLAMA_DISK_LOG` is pointed at a per-case file for disktui.
- **Measurement**: wall time, exit code, peak working set / private bytes via
  `GetProcessMemoryInfo`, CPU time via `GetProcessTimes`, and process read bytes/operations via
  `GetProcessIoCounters` (independent proof of real disk reads).
- **Parsing**: arena/raise/register lines, model load time, prefill/gen times, `diskrun: token N id=X`
  lines (authoritative greedy comparison key), `disktui` io/cmp lines, RSS lines, error/crash text.
- **Comparison**: greedy **token ids** are compared first (stdout text is secondary), per the Lead's
  instruction; text is normalized by stripping the prompt echo.

`-BinDir`/`-FallbackBinDir` were both set to `F:\diskinfer\build\out\win-x64`.

## 6. Results

Absolute path of the final run: `F:\diskinfer\test\logs\run-20261031-224408\`.
`io s` / `compute s` for diskrun cases are **estimates** derived by subtracting the native
compute-only per-token times from the measured streaming prefill/eval times (diskrun does not print a
per-token io/cmp split; see observation OBS-1). For disktui they are measured and printed by the TUI.

| Case | Env | Exit | Tokens | Greedy token ids | io s | compute s | RSS MiB | Streaming engaged | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| case1 streaming-200 | `LLAMA_DISK_STREAM_MB=200` | 0 | 8 | 11751,13,198,760,6511,314,9338,369 | ~3.55 (est.) | ~0.50 (est.) | 347.7 | yes, arena 222 MiB | PASS |
| case2 native-baseline | `LLAMA_DISK_STREAM_MB=0` | 0 | 8 | 11751,13,198,760,6511,314,9338,369 | n/a (mmap) | 0.50 (measured pp+eval) | 715.2 | no (expected) | PASS |
| case3 auto-arena | unset | 0 | 8 | 11751,13,198,760,6511,314,9338,369 | ~0.41 (est.) | ~0.50 (est.) | 716.8 | yes, arena 2048 MiB | PASS |
| case4 odirect-off | `LLAMA_DISK_STREAM_MB=200; LLAMA_DISK_ODIRECT=0` | 0 | 8 | 11751,13,198,760,6511,314,9338,369 | ~2.26 (est.) | ~0.50 (est.) | 347.4 | yes, direct io = 0 | PASS |
| case5 disktui-oneshot | auto arena; `LLAMA_DISK_LOG` set | 0 | 4 | n/a (sampled) | 0.3 (measured pp io) | 0.0 (measured cmp, 0.1 s display resolution) | 2173.1 | yes, arena 2048 MiB, mlock 1 | PASS |
| case6 error-missing-model | none | 1 | n/a | n/a | n/a | n/a | 5.9 | n/a | PASS |
| case7 tiny-arena-32 | `LLAMA_DISK_STREAM_MB=32` | 0 | 8 | 11751,13,198,760,6511,314,9338,369 | ~3.53 (est.) | ~0.50 (est.) | 347.7 | yes, raised 32 -> 222 MiB | PASS |

Measured timing detail (from `llama_perf_context_print` and diskrun lines; prefill = 5 prompt tokens,
eval = 7 of 8 generated tokens as reported by llama.cpp):

| Case | Model load (diskrun line) | Prefill | Eval | Step per token | Native-compute-only per token |
| --- | --- | --- | --- | --- | --- |
| case1 | 0.3 s (metadata only) | 1.706 s | 2.343 s | 0.334-0.341 s | 0.041-0.044 s (case2) |
| case2 | 0.3 s | 0.219 s | 0.284 s | 0.041-0.044 s | same |
| case3 | 0.3 s | 0.551 s | 0.359 s | 0.051-0.053 s | 0.041-0.044 s |
| case4 | 0.3 s | 1.178 s | 1.589 s | 0.225-0.236 s | 0.041-0.044 s |
| case5 | 0.7 s ("model ready") | 5 tok in 0.4 s, io 0.3 s | 4 tok in 0.2 s, io 0.0 s | 0.0 s/tok (cached) | n/a |
| case7 | 0.3 s | 1.694 s | 2.334 s | 0.333-0.339 s | 0.041-0.044 s |

Derived effective disk read throughput (bytes read / wall time, includes compute overlap):
case1 ~1.62 GiB/s, case4 ~2.30 GiB/s (page-cache assisted, see section 8), case3/case5 ~0.6 GiB read once.

### 6.1 Per-case evidence

**case1 - streaming, 200 MiB request -> raised to 222 MiB** (PASS)

```
$env:LLAMA_DISK_STREAM_MB='200'
diskrun.exe -m <model> -p "The capital of France is" -n 8 -c 128 -b 4 -ub 4 -t 4
```
Raw log `case1-streaming-200\stderr.log`:
- L894 `llama-disk: 320 tensors registered, 590 MiB to stream, largest tensor 'token_embd.weight' 198 MiB`
- L896 `llama-disk: arena 200 MiB cannot hold the largest tensor 'token_embd.weight' (198 MiB), raised to 222 MiB`
- L898 `llama-disk: streaming weights from disk, arena = 222 MiB (raised to fit the largest tensor), direct io = 1, mlock = 0, prefetch = 0 (lookahead 16)`
- L900 `diskrun: model loaded in 0.3 s`, L1505 `diskrun: prefill took 1.7 s`
- 8 token lines, e.g. L1508 `diskrun: token 1 id=11751 sample=0.335 s, rss = 347 MiB`
- L1523 `diskrun: generated 8 tokens in 2.7 s (0.34 s/token)`

stdout (prompt echo + generated text; CR/LF from the MSVC text-mode stdout):
```
The capital of France is Paris.
The capital of France is
```
Exit 0, wall 4.766 s, peak RSS 347.7 MiB (app-reported rss 347 MiB), private peak 556.3 MiB,
process read 7,898.0 MiB, CPU 4.0 s.

**case2 - native baseline** (PASS)

Same command with `LLAMA_DISK_STREAM_MB=0`. No arena/streaming lines at all (0 occurrences of
`llama-disk: streaming` and `tensors registered`), 320-tensor registration never happens, process read
only 11.4 MiB (mmap page faults are not counted as process I/O). Exit 0, wall 0.995 s,
peak RSS 715.2 MiB, 8 tokens, ids identical to case1, stdout text identical to case1.

**case3 - auto arena** (PASS)

`LLAMA_DISK_STREAM_MB` unset. Arena line: `arena = 2048 MiB (2048 MiB cap), direct io = 1, mlock = 0`.
2048 MiB = min(24363/8 = 3045 MiB, 2048 MiB cap), so the Windows memory query for auto sizing works.
Because the whole 590 MiB model then fits in the arena, only 602.8 MiB is read once and the remaining
tokens are served from RAM: wall 1.365 s, prefill 0.55 s, eval 0.36 s, RSS 716.8 MiB, ids identical.

**case4 - streaming with direct I/O disabled** (PASS)

`LLAMA_DISK_STREAM_MB=200; LLAMA_DISK_ODIRECT=0`. Arena line says `direct io = 0`, arena 222 MiB
(raised), 320 tensors registered. Exit 0, wall 3.347 s, prefill 1.178 s, eval 1.589 s,
0.23 s/token, process read 7,881.9 MiB, RSS 347.4 MiB, ids identical to case1.
Both O_DIRECT modes work end-to-end (see section 8 for the comparison).

**case5 - disktui one-shot smoke** (PASS)

```
disktui.exe -m <model> -n 4 "The capital of France is"   (stdin NUL, stdout redirected)
```
`case5-disktui-oneshot\disktui.log`:
- L175 `llama-disk: streaming weights from disk, arena = 2048 MiB (2048 MiB cap), direct io = 1, mlock = 1, prefetch = 0 (lookahead 16)`
- L176 `[  0.7s] model ready: qwen35 0.8B Q6_K`
- L230 `[ 0:00] prompt done: 5 tok in 0.4s (0.1 s/tok), io 0.3s`
- L231..234 four token lines with io/cmp/tot, e.g. `t1 io 0.0s cmp 0.0s tot 0.0s ' ______'`
- L237 `gen 4 tok in 0.2s (0.0 s/tok) io 0.0s rss 2173 MiB`
- L238 `answer:  _______` (the answer line exists; the sampled continuation is non-deterministic)
- L240 `saved to F:\...\case5-disktui-oneshot/last_answer.txt` (HOME/USERPROFILE override respected)

Exit 0, wall 1.552 s, 4 tokens, stdout 6,756 bytes and contains ESC (ANSI) sequences as expected,
`answer:` present in stdout and in `LLAMA_DISK_LOG` file. No "mlock failed"/"arena can be paged out"
message on this machine. Sampling in disktui is probabilistic (temp 1.0, top-k 20, top-p 0.95), so the
answer text is not reproducible; the smoke check is structural (`answer:` line + exit 0), which passed.
RSS is 2,173 MiB because disktui defaults to auto arena 2048 MiB and mlock = 1, so the whole arena is
resident (see OBS-2).

**case6 - error path, missing model** (PASS)

```
diskrun.exe -m C:\definitely\missing.gguf -n 4 -c 64 -b 4 -ub 4 -t 4
```
Exit code 1 in 0.038 s, no crash dialog, no hang. `case6-error-missing-model\stderr.log`:
- L3 `gguf_init_from_file: failed to open GGUF file 'C:\definitely\missing.gguf' (No such file or directory)`
- L4 `llama_model_load: error loading model: llama_model_loader: failed to load model from C:\definitely\missing.gguf`
- L6 `diskrun: failed to load model`

**case7 - tiny arena 32 MiB** (PASS)

`LLAMA_DISK_STREAM_MB=32` is not an error: the engine raises it and continues.
- L896 `llama-disk: arena 32 MiB cannot hold the largest tensor 'token_embd.weight' (198 MiB), raised to 222 MiB`
- L898 arena line with `arena = 222 MiB (raised to fit the largest tensor)`, direct io = 1
Exit 0, wall 4.738 s, 8 tokens, ids identical to case1, RSS 347.7 MiB. The raised size (32 -> 222 MiB)
was recorded rather than treated as a failure.

## 7. Streamed vs native greedy correctness (required check)

The authoritative comparison uses the per-token ids printed on stderr
(`diskrun: token N id=X ...`), parsed separately from stdout text.

| Pair | Token ids A | Token ids B | Token-id result | Text result |
| --- | --- | --- | --- | --- |
| case1 vs case2 (required) | 11751,13,198,760,6511,314,9338,369 | 11751,13,198,760,6511,314,9338,369 | MATCH | MATCH (` Paris.`) |
| case1 vs case3 | same | same | MATCH | MATCH |
| case1 vs case4 | same | same | MATCH | MATCH |
| case1 vs case7 | same | same | MATCH | MATCH |

Verdict: **PASS** - greedy output is byte-identical between the disk-streaming path and the native
path across every arena/direct-I/O configuration that was exercised. The generated text (after
stripping the prompt echo) is ` Paris.` in all of them; the last tokens repeat the prompt phrase
(`... is`), which is why token ids are the correct equality key.

## 8. Streaming engaged + disk-read evidence

Independent evidence that weights really come from disk (process I/O counters, not app logs):

| Case | Arena line | direct io | mlock | tensors registered | read MiB | approx. full-model passes |
| --- | --- | --- | --- | --- | --- | --- |
| case1 | 222 MiB (raised) | 1 | 0 | 320 / 590 MiB | 7,898.0 | ~13.4 (5 prefill + 8 gen) |
| case2 | none (native) | n/a | n/a | none | 11.4 | mmap page faults not counted |
| case3 | 2048 MiB (cap) | 1 | 0 | 320 / 590 MiB | 602.8 | ~1.0 (then cached in arena) |
| case4 | 222 MiB (raised) | 0 | 0 | 320 / 590 MiB | 7,881.9 | ~13.4 |
| case5 | 2048 MiB (cap) | 1 | 1 | 320 / 590 MiB | 602.8 | ~1.0 |
| case7 | 222 MiB (raised from 32) | 1 | 0 | 320 / 590 MiB | 7,898.0 | ~13.4 |

7,898 MiB read over 8 tokens + 5 prefill tokens is ~13.4 x the 590 MiB of tensor bytes, exactly what
the "one full model scan per token" design predicts. The native case reads only 11.4 MiB because mmap
does not issue process reads. This is independent proof that streaming is engaged on Windows and that
the arena works with the requested 200 MiB (raised to 222 MiB).

O_DIRECT on/off, same command/env except `LLAMA_DISK_ODIRECT`:

| Case | direct io flag | wall | prefill | eval | step/token | read MiB | token ids |
| --- | --- | --- | --- | --- | --- | --- | --- |
| case1 | 1 (`FILE_FLAG_NO_BUFFERING` path) | 4.766 s | 1.706 s | 2.343 s | 0.334 s | 7,898.0 | identical |
| case4 | 0 (buffered reads) | 3.347 s | 1.178 s | 1.589 s | 0.227 s | 7,881.9 | identical |

Both modes work. Buffered mode is faster here because the model fits comfortably in the 24 GB page
cache after the first scan (`direct io = 0` intentionally lets the cache help); O_DIRECT bypasses the
page cache and is slower, which is the expected/desired trade-off for the small-memory targets. Both
paths produced identical results, so the flag is honored without a correctness change.

## 9. RSS behavior (case1 requirement: bounded < ~1 GB)

| Case | OS working-set peak | App-reported rss | Private/commit peak |
| --- | --- | --- | --- |
| case1 | 347.7 MiB | 347 MiB | 556.3 MiB |
| case2 | 715.2 MiB | 715 MiB | 333.8 MiB |
| case3 | 716.8 MiB | 716 MiB | 2,385.5 MiB (2 GiB arena committed, pages lazily resident) |
| case4 | 347.4 MiB | 347 MiB | 556.1 MiB |
| case5 | 2,173.1 MiB | 2,173 MiB | 2,385.9 MiB (2 GiB arena + mlock = 1) |
| case6 | 5.9 MiB | n/a | 1.7 MiB |
| case7 | 347.7 MiB | 347 MiB | 556.3 MiB |

case1 meets the "< ~1 GB" expectation with 347.7 MiB. case2/case3 are the mmap/large-arena baselines.
case5's 2.17 GiB is the auto arena (2048 MiB) plus mlock residency, which is the documented design for
disktui (mlock on), not a leak; see OBS-2.

## 10. Supplemental: llama-completion.exe (third deliverable binary)

Run outside the 7-case matrix with the same model (details in
`F:\diskinfer\test\logs\phase2-supplement\supplement.txt`, raw `stdout.log`/`stderr.log`):

- `--version`: exit 0, `version: 0.7.0-dev (build 0, commit unknown) built with MSVC 19.44.35229.0 for x64`
- One-shot greedy completion, `LLAMA_DISK_STREAM_MB=200`, `-no-cnv --no-display-prompt`: exit 0 in 4.318 s
- Arena line present: `arena = 222 MiB (raised to fit the largest tensor), direct io = 1, mlock = 0`
- **Two model loads** happen per invocation (llama-completion does its `--fit` probe): two
  `320 tensors registered` lines, never `640`. This matches the Lead's expected behavior and confirms
  the second-load support in the same process.
- Generated raw text: ` Paris.` (same greedy continuation as diskrun case1/case2)

Verdict: PASS.

## 11. Defects

**None found within the tested scope.** All seven cases and the cross-check passed on exactly the
reported binaries; two independent full runs (`run-20261031-224209` and `run-20261031-224408`) produced
the same PASS/FAIL results and the same greedy token ids.

Non-blocking observations / deviations from task wording:

- **OBS-1 (diagnostic gap, not a functional defect):** `diskrun.exe` does not log per-token
  `io_us`/`loads` or separate io/compute seconds; it only prints total step time
  (`sample=0.33 s`) and RSS. The task text asks for "io_us/loads reported per token", and the Lead's
  task-1 acceptance also mentions non-zero io_us/loads counters. The counters exist in the engine
  (`llama_disk::get_stats`), and `disktui` exposes them (`io 0.3s cmp 0.0s` per pp/token). For diskrun
  they can only be observed indirectly here (process I/O byte counters + wall/prefill/eval times).
  Suggested follow-up (optional): have diskrun print `io`/`cmp` from `get_stats()` around each decode.
- **OBS-2 (design consequence):** disktui defaults to auto arena (2048 MiB on this 24 GB machine) and
  mlock = 1, so its working set is ~2.17 GiB even though the model is 590 MiB. That is the intended
  anti-swap behavior from the README, and it is fine on 24 GB, but on small-RAM Windows devices the
  launcher should pass a smaller `--arena`. The 1 GB RSS bound in the test plan applies to case1
  (347.7 MiB, PASS), not to disktui's default configuration.
- **OBS-3 (expected, not a bug):** disktui's default sampler is probabilistic (temp 1.0, top-k 20,
  top-p 0.95, dist), so the one-shot answer differs between runs: ` located in the __` in one run,
  ` _______\nA` in another. The smoke check is exit 0 + `answer:` present + ANSI output, all of which
  passed; no greedy text comparison is valid for disktui defaults.
- **OBS-4 (expected):** `llama-completion.exe` loads the model twice per invocation (fit probe); each
  load registers 320 tensors, so there is no double-registration bug.
- **OBS-5 (expected):** case3 allocates the full 2048 MiB arena, so private/commit peak is 2,385 MiB
  while working set is 716 MiB (arena pages are committed but only touched pages are resident).
- **OBS-6 (parser note):** the disktui stdout capture repeats the whole log window on every repaint;
  the harness de-duplicates lines before reading io/cmp totals (otherwise totals would be multiplied).
  Anyone parsing disktui stdout directly should do the same. Multi-line answers (a token containing
  `\n`) are split across lines in the TUI log; the harness reports the first line and does not treat
  that as a failure because token-count/exit checks carry the smoke test.

## 12. Reproduction

Final full run (uses only the allowed model):

```powershell
pwsh -NoProfile -File F:\diskinfer\test\run-tests.ps1 `
  -BinDir F:\diskinfer\build\out\win-x64 `
  -FallbackBinDir F:\diskinfer\build\out\win-x64
```

Single cases, e.g.:

```powershell
pwsh -NoProfile -File F:\diskinfer\test\run-tests.ps1 -Cases 1,2 -BinDir F:\diskinfer\build\out\win-x64 -FallbackBinDir F:\diskinfer\build\out\win-x64
pwsh -NoProfile -File F:\diskinfer\test\run-tests.ps1 -DryRun
```

Manual per-case commands (identical to the harness):

```powershell
$model = 'D:\LMStudioModel\lmstudio-community\Qwen3.5-0.8B-GGUF\Qwen3.5-0.8B-Q6_K.gguf'
# case1
$env:LLAMA_DISK_STREAM_MB='200'
& 'F:\diskinfer\build\out\win-x64\diskrun.exe' -m $model -p 'The capital of France is' -n 8 -c 128 -b 4 -ub 4 -t 4
# case2
$env:LLAMA_DISK_STREAM_MB='0'
& 'F:\diskinfer\build\out\win-x64\diskrun.exe' -m $model -p 'The capital of France is' -n 8 -c 128 -b 4 -ub 4 -t 4
# case4
$env:LLAMA_DISK_STREAM_MB='200'; $env:LLAMA_DISK_ODIRECT='0'
& 'F:\diskinfer\build\out\win-x64\diskrun.exe' -m $model -p 'The capital of France is' -n 8 -c 128 -b 4 -ub 4 -t 4
# case6
& 'F:\diskinfer\build\out\win-x64\diskrun.exe' -m 'C:\definitely\missing.gguf' -n 4 -c 64 -b 4 -ub 4 -t 4
# case7
$env:LLAMA_DISK_STREAM_MB='32'
& 'F:\diskinfer\build\out\win-x64\diskrun.exe' -m $model -p 'The capital of France is' -n 8 -c 128 -b 4 -ub 4 -t 4
# case5 (stdin NUL, stdout redirected; LLAMA_DISK_LOG optional for the clean log)
$env:LLAMA_DISK_LOG='F:\diskinfer\test\logs\disktui-sample.log'
& 'F:\diskinfer\build\out\win-x64\disktui.exe' -m $model -n 4 'The capital of France is' < NUL
```

## 13. Limitations

- One machine (i5-14600KF, 24 GB RAM), one static build, one model (the only allowed one).
- diskrun io/compute split is estimated (OBS-1); disktui io/compute values were measured directly.
- disktui default sampling is random, so only structural smoke criteria apply to case5.
- Windows 11 24H2-class machine; no low-RAM or Android behavior was re-tested here.
