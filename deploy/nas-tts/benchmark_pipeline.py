"""Isolated benchmark. Run only while the production worker is stopped.

Never modifies the production module, weights, voices, cache or token.
Results validate numerical audio, not semantic completeness or subjective quality.
"""
import argparse
import json
import os
import time
from pathlib import Path

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
import numpy as np
import soundfile as sf
import torch
from qwen_tts import Qwen3TTSModel


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--attention', choices=['eager', 'sdpa'], required=True)
    parser.add_argument('--skip-decode', action='store_true')
    parser.add_argument('--greedy-subtalker', action='store_true')
    parser.add_argument('--fixed-predictor', action='store_true')
    parser.add_argument('--threads', type=int, choices=[1, 2, 4, 6], default=4)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(args.threads)
    root = Path('/opt/guiye-tts')
    started = time.perf_counter()
    model = Qwen3TTSModel.from_pretrained(str(root / 'model'), device_map='cuda:0',
        dtype=torch.bfloat16, attn_implementation=args.attention, local_files_only=True)
    reference = '你回来啦，今天辛苦了。要不要坐下来，让我陪你读一会儿书？别着急，今晚的故事，我们慢慢听。'
    with torch.inference_mode():
        prompts = {v: model.create_voice_clone_prompt(ref_audio=str(root / 'voices' / (name + '.wav')),
                   ref_text=reference) for v, name in [('1', 'gentle'), ('4', 'coaxing')]}
    tokenizer = model.model.speech_tokenizer
    tokenizer.model.to(device='cpu', dtype=torch.float32)
    tokenizer.device = torch.device('cpu')
    torch.cuda.empty_cache()
    if args.fixed_predictor:
        # This predictor always emits the remaining 15 codebooks and has no EOS.
        # Avoid synchronizing a GPU boolean after each of those fixed steps.
        # The outer talker retains its normal EOS/length stopping checks.
        predictor = model.model.talker.code_predictor
        assert predictor.generation_config.eos_token_id is None
        original_predict = predictor.generate
        original_unfinished = predictor._has_unfinished_sequences
        state = {'remaining': None}

        def fixed_unfinished(this_peer_finished, synced_gpus, device):
            if state['remaining'] is None or synced_gpus:
                return original_unfinished(this_peer_finished, synced_gpus, device)
            more = state['remaining'] > 0
            state['remaining'] -= 1
            return more

        def fixed_predict(*a, **kw):
            assert kw.get('max_new_tokens') == 15
            assert kw.get('eos_token_id') is None and not kw.get('stopping_criteria')
            assert kw['inputs_embeds'].shape[0] == 1
            state['remaining'] = 15
            try:
                result = original_predict(*a, **kw)
                assert result.sequences.shape[-1] == 15
                return result
            finally:
                state['remaining'] = None

        predictor._has_unfinished_sequences = fixed_unfinished
        predictor.generate = fixed_predict
    print(json.dumps({'phase': 'loaded', 'seconds': time.perf_counter()-started}), flush=True)
    original_generate = model.model.generate
    original_decode = tokenizer.decode
    timing = {}
    captured = {}

    def timed_generate(*a, **kw):
        torch.cuda.synchronize()
        t = time.perf_counter()
        result = original_generate(*a, **kw)
        torch.cuda.synchronize()
        timing['generation_seconds'] = time.perf_counter() - t
        timing['generated_frames'] = [len(c) for c in result[0]]
        return result

    def timed_decode(*a, **kw):
        torch.cuda.synchronize()
        t = time.perf_counter()
        result = original_decode(*a, **kw)
        timing['decode_seconds'] = time.perf_counter() - t
        captured['args'], captured['kwargs'] = a, kw
        return result

    model.model.generate = timed_generate
    tokenizer.decode = timed_decode
    cases = [('short', '你好，今天我们一起读书。'),
             ('medium', '夜色渐渐安静下来，她轻轻翻开书页，微笑着说：别着急，我们一起慢慢读。最后一句，今天的故事到这里结束。')]
    results = []
    with torch.inference_mode():
        for voice in ['1', '4']:
            for name, text in cases:
                torch.manual_seed(42)
                timing.clear()
                t = time.perf_counter()
                wavs, rate = model.generate_voice_clone(text=text, language='Chinese',
                    voice_clone_prompt=prompts[voice], max_new_tokens=512,
                    **({'subtalker_dosample': False} if args.greedy_subtalker else {}))
                elapsed = time.perf_counter()-t
                audio = np.asarray(wavs[0], dtype=np.float32)
                assert audio.size and np.isfinite(audio).all()
                assert max(timing['generated_frames']) < 512, 'generation hit token limit'
                duration = len(audio)/rate
                row = dict(attention=args.attention, voice=voice, case=name, characters=len(text),
                    greedy_subtalker=args.greedy_subtalker, threads=args.threads,
                    fixed_predictor=args.fixed_predictor,
                    total_seconds=elapsed, audio_seconds=duration, rtf=elapsed/duration,
                    peak=float(np.max(np.abs(audio))), **timing)
                sf.write(args.output / f'{args.attention}-{voice}-{name}.wav', audio, rate, subtype='PCM_16')
                results.append(row)
                print(json.dumps(row), flush=True)
        # Identical captured codes isolate decoder threading, without generating more text.
        for threads in ([] if args.skip_decode else [1, 2, 4, 6]):
            torch.set_num_threads(threads)
            for repeat in range(2):
                t = time.perf_counter()
                decoded, rate = original_decode(*captured['args'], **captured['kwargs'])
                seconds = time.perf_counter()-t
                assert all(np.isfinite(x).all() for x in decoded)
                row = dict(phase='decoder_replay', threads=threads, repeat=repeat, seconds=seconds)
                results.append(row)
                print(json.dumps(row), flush=True)
    (args.output / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
