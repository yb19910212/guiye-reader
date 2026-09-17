# NAS TTS performance tests — 2026-09-17

## Scope and safeguards
User authorized testing and confirmed the app was closed. The last active request finished before testing. Only CT 102 speech service was paused/restarted; no PVE/VM hardware, GPU driver or fnOS configuration was changed. Original server and service copies are at `/opt/guiye-tts/bench-20260917/server.before.py` and `service.before`. Tests ran as transient services with a 6 GB memory cap, 6-CPU quota, timeout, and restore hook. Repeated restarts hit the existing service start limit once; resetting that failed state restored it. No model, reference voice, key, or existing audio cache was removed.

## Method
Same local Qwen3-TTS 0.6B BF16 weights, reference voices 1/4, seed 42, CPU FP32 audio decoder, 512-token cap. Short text: 12 characters; medium: 50 characters. CUDA synchronization brackets model generation; decoder measured separately. Four candidate configurations and 1/2/4/6-thread decoder replays were tested. These are small single-run generation samples, not population averages. Audio finite samples, nonempty WAV and token-limit checks passed; no ASR or human listening validation was performed.

## Medium-text results
| Configuration | Voice | Total seconds | Audio seconds | Generate seconds per audio second |
|---|---|---:|---:|---:|
| Original eager / 4 threads | 1 | 31.77 | 11.68 | 2.72 |
| Original eager / 4 threads | 4 | 33.52 | 12.24 | 2.74 |
| SDPA / 4 threads | 1 | 25.96 | 10.80 | 2.40 |
| SDPA / 4 threads | 4 | 26.20 | 10.64 | 2.46 |
| SDPA / fixed predictor stop check | 1 | 25.80 | 10.80 | 2.39 |
| SDPA / fixed predictor stop check | 4 | 25.71 | 10.64 | 2.42 |
| SDPA / greedy sub-predictor | 1 | 29.32 | 12.32 | 2.38 |
| SDPA / greedy sub-predictor | 4 | 30.20 | 12.56 | 2.40 |

SDPA reduces this medium-text total latency by 18–22%; normalized for different generated audio durations, the reduction in real-time factor is about 10–12%. Short samples are mixed: SDPA is not uniformly better on every RTF measurement. No configuration reached real time.

Decoder replay means for identical codes: 1 thread 18.05 s; 2 threads 10.97 s; 4 threads 6.84 s; 6 threads 7.09 s. Keep 4 threads.

The fixed-step experimental wrapper produced byte-identical WAVs to normal SDPA for all four cases, but its sub-2% improvement is too small to justify maintaining a private generation-method override. It was NOT deployed. Greedy sampling changed audio without compelling latency improvement; NOT deployed.

## Applied configuration
Only `/etc/systemd/system/guiye-tts.service.d/30-guiye-sdpa-20260917.conf` was added: `Environment=GUIYE_ATTENTION=sdpa`. Original sampling, voices, CPU thread count, weights and API remain unchanged. Rollback is removal of that one override followed by daemon reload and restart, during an idle maintenance window.

Public API verification after restart, both cache misses:
- Voice 1: HTTP 200, generation 27.893 s, total 28.383 s, audio 10.96 s.
- Voice 4: HTTP 200, generation 25.356 s, total 25.731 s, audio 10.32 s.
- Both downloaded files are mono PCM16 WAV at 24 kHz. `/health` returned ready; fnOS VM 100 remained running.

Raw results and WAVs: `downloads/nas-benchmark-20260917/{eager,sdpa,fixed,greedy}/`; public samples `public-voice-1.wav` and `public-voice-4.wav`. Remote original artifacts remain under `/opt/guiye-tts/bench-20260917`.

This is a measured improvement, not a claim of the fastest possible engine or real-time synthesis. Testing a different fast voice is a separate decision; original voices must remain available.
