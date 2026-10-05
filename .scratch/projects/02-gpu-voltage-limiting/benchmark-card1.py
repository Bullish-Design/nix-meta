#!/usr/bin/env python3
"""Measure Qwen on V620 card1 while the production router is stopped."""

import argparse
import hashlib
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

REPO = Path('/home/andrew/Documents/Projects/inferference')
SERVER_DIR = REPO / 'ci/modea/server/vulkan-mi25-p2fork-server-ecc0cb0d3'
SERVER = SERVER_DIR / 'bin/llama-server'
MODEL = Path('/mnt/shared/ai/models/qwen3.8-27b-gguf/unsloth/Qwen3.8-27B-UD-Q4_K_XL.gguf')
ART_ROOT = Path('/mnt/shared/ai/models/qwen3.8-27b-gguf/artifacts')
EXPECTED_SHA256 = 'bee238bbeb3dc0a34bde4d0dedbaee1f98c009e8bb4226f03070054c12fb1372'
PORT = 18170
MIB = 1048576
EXPERIMENT_STOP_C = 72
SOAK_SECONDS = 15 * 60
SOAK_MIN_PROMPT_TOKENS = 8192
SOAK_MIN_COMPLETION_TOKENS = 1536
SOAK_MIN_REASONING_TOKENS = 1024
SOAK_MIN_REASONING_CHARACTERS = 4000


def utc():
    return datetime.now(timezone.utc).isoformat()


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError as exc:
        return f'ERROR:{exc.errno}'


def model_sha256():
    digest = hashlib.sha256()
    with MODEL.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def controls(device):
    profile = read(device / 'pp_power_profile_mode')
    offset = read(device / 'pp_od_clk_voltage')
    selected = re.search(r'(?m)^\s*(\d+)\s+[^\n]*\*:', profile)
    voltage = re.search(r'OD_VDDGFX_OFFSET:\s*([-+]?\d+)mV', offset)
    return {
        'performance_level': read(device / 'power_dpm_force_performance_level'),
        'profile_index': int(selected.group(1)) if selected else None,
        'offset_mv': int(voltage.group(1)) if voltage else None,
    }


def snapshot():
    data = {'utc': utc(), 'cards': {}, 'fan': {}}
    for index in (0, 1):
        device = Path(f'/sys/class/drm/card{index}/device')
        h = next(p for p in (device / 'hwmon').glob('hwmon*') if read(p / 'name') == 'amdgpu')
        data['cards'][str(index)] = {
            'pci': device.resolve().name,
            'vram_used_bytes': int(read(device / 'mem_info_vram_used')),
            'vram_total_bytes': int(read(device / 'mem_info_vram_total')),
            'gtt_used_bytes': int(read(device / 'mem_info_gtt_used')),
            'power_uw': read(h / 'power1_average'),
            'voltage_mv': read(h / 'in0_input'),
            'freq1_hz': read(h / 'freq1_input'),
            'freq2_hz': read(h / 'freq2_input'),
            'dpm_sclk': read(device / 'pp_dpm_sclk'),
            'dpm_mclk': read(device / 'pp_dpm_mclk'),
            'controls': controls(device),
            'temperatures': {read(p.with_name(p.name.replace('_input', '_label'))): int(read(p)) for p in h.glob('temp*_input')},
        }
    fan = Path('/sys/class/hwmon/hwmon2')
    data['fan'] = {'pwm1': read(fan / 'pwm1'), 'fan1_rpm': read(fan / 'fan1_input')}
    return data


def exact_server_pids(port):
    result = []
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            argv = (proc / 'cmdline').read_bytes().split(b'\0')
        except OSError:
            continue
        args = [x.decode(errors='replace') for x in argv if x]
        if not args or args[0] != str(SERVER):
            continue
        if '--port' not in args or '--model' not in args:
            continue
        if args[args.index('--port') + 1] != str(port):
            continue
        if args[args.index('--model') + 1] != str(MODEL):
            continue
        result.append(int(proc.name))
    return result


def stop_exact_server(port, sig=signal.SIGTERM):
    pids = exact_server_pids(port)
    for pid in pids:
        os.kill(pid, sig)
    return pids


def api(port, path, payload=None, timeout=120):
    url = f'http://127.0.0.1:{port}{path}'
    raw = None if payload is None else json.dumps(payload).encode()
    request = Request(url, data=raw, headers={'Content-Type': 'application/json'}, method='GET' if raw is None else 'POST')
    started = time.monotonic()
    try:
        with urlopen(request, timeout=timeout) as response:
            body = response.read().decode(errors='replace')
            status = response.status
    except HTTPError as exc:
        body = exc.read().decode(errors='replace')
        status = exc.code
    return {'status': status, 'elapsed_s': time.monotonic() - started, 'body': body}


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def request_cases():
    rows = [f'EVT-{index:03d} severity={"ALERT" if index % 7 == 0 else "INFO"} value={index % 13}' for index in range(150)]
    common = {'model': 'qwen38-27b', 'temperature': 0, 'seed': 42, 'stream': False,
              'chat_template_kwargs': {'enable_thinking': False}}
    return [
        ('prompt', dict(common, max_tokens=128, messages=[
            {'role': 'system', 'content': 'Read the records and answer in one sentence.'},
            {'role': 'user', 'content': '\n'.join(rows) + '\nWhat is the last event ID, and what is its severity? Answer in one sentence.'}])),
        ('decode', dict(common, max_tokens=900, messages=[
            {'role': 'system', 'content': 'Write direct, useful prose. Do not include reasoning.'},
            {'role': 'user', 'content': 'Write exactly 20 numbered rules for measuring the performance and placement of a Vulkan language-model server. Give two specific sentences per rule. Cover device identity, memory residency, prompt processing, decoding, output checks, concurrency, and temperature. No preamble.'}])),
    ]


def validate(case, result):
    if result['status'] != 200:
        return {'ok': False, 'reason': f'HTTP {result["status"]}'}
    try:
        data = json.loads(result['body'])
        message = data['choices'][0]['message']
        content = message.get('content') or ''
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        return {'ok': False, 'reason': f'bad response: {exc}'}
    if case == 'prompt':
        ok = 'EVT-149' in content and 'INFO' in content
    else:
        ok = len(content) >= 400 and all(re.search(rf'(?m)^\s*{n}[.)]', content) for n in (1, 10, 20))
    return {'ok': bool(ok), 'content_length': len(content), 'usage': data.get('usage'), 'timings': data.get('timings'),
            'reason': None if ok else 'content did not meet the case check'}


def soak_request(cycle):
    rows = []
    for index in range(600):
        junction = 42 + (index * 7 + cycle * 3) % 27
        power = 142 + (index * 11 + cycle * 5) % 91
        queue = (index * 13 + cycle * 17) % 38
        errors = 1 if (index + cycle * 19) % 47 == 0 else 0
        rows.append(f'SAMPLE-{index:04d} minute={index // 4:03d} card=1 '
                    f'junction_c={junction} edge_c={junction - 8} power_w={power} '
                    f'fan_rpm={2260 + (index * 17) % 790} queue={queue} errors={errors}')
    question = (
        f'This is a synthetic GPU server log for analysis cycle {cycle}. '
        'Review the full log. Identify the hottest samples, the largest queues, '
        'and the error samples. Compare the first and last quarters. '
        'Explain how temperature, power, fan speed, and queue depth relate in this log. '
        'Give at least twelve numbered findings, cite sample IDs and values, '
        'show the calculations behind at least three comparisons, and finish with '
        'a practical monitoring plan. Check your evidence before you answer.\n\n'
        + '\n'.join(rows)
    )
    return {'model': 'qwen38-27b', 'temperature': 0, 'seed': 42 + cycle,
            'stream': False, 'max_tokens': 6144,
            'reasoning_effort': 'xhigh',
            'chat_template_kwargs': {'enable_thinking': True, 'preserve_thinking': True},
            'messages': [
                {'role': 'system', 'content': 'Analyze the evidence carefully before writing a detailed final report.'},
                {'role': 'user', 'content': question},
            ]}


def validate_soak(result):
    if result['status'] != 200:
        return {'ok': False, 'reason': f'HTTP {result["status"]}'}
    try:
        data = json.loads(result['body'])
        choice = data['choices'][0]
        message = choice['message']
        content = message.get('content') or ''
        usage = data['usage']
        prompt_tokens = int(usage['prompt_tokens'])
        completion_tokens = int(usage['completion_tokens'])
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        return {'ok': False, 'reason': f'bad response: {exc}'}
    reasoning = message.get('reasoning_content') or ''
    if not reasoning:
        match = re.search(r'<think>(.*?)</think>', content, re.DOTALL)
        reasoning = match.group(1) if match else ''
    details = usage.get('completion_tokens_details') or {}
    reported_reasoning_tokens = int(details.get('reasoning_tokens') or 0)
    checks = {
        'prompt_tokens': SOAK_MIN_PROMPT_TOKENS <= prompt_tokens <= 32000,
        'completion_tokens': completion_tokens >= SOAK_MIN_COMPLETION_TOKENS,
        'reasoning': (reported_reasoning_tokens >= SOAK_MIN_REASONING_TOKENS
                      or len(reasoning) >= SOAK_MIN_REASONING_CHARACTERS),
        'final_answer': len(content) >= 1200,
        'completed': choice.get('finish_reason') == 'stop',
    }
    return {'ok': all(checks.values()), 'checks': checks, 'usage': usage,
            'timings': data.get('timings'), 'elapsed_s': result['elapsed_s'],
            'content_length': len(content), 'reasoning_length': len(reasoning),
            'reported_reasoning_tokens': reported_reasoning_tokens,
            'finish_reason': choice.get('finish_reason')}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('label', choices=('baseline', 'low', 'manual-default', 'power-saving',
                                          'power-saving-soak', 'compute', 'undervolt'))
    parser.add_argument('--expected-performance-level', default='auto')
    parser.add_argument('--expected-profile', type=int, default=0)
    parser.add_argument('--expected-offset-mv', type=int, default=0)
    args = parser.parse_args()
    if args.label == 'power-saving-soak' and (args.expected_performance_level,
                                              args.expected_profile, args.expected_offset_mv) != ('manual', 2, 0):
        parser.error('the power-saving soak requires manual mode, profile 2, and 0 mV')
    parallel = 2
    ctx = 40960 * parallel
    port = PORT
    stamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')
    out = ART_ROOT / stamp / f'02-v620-{args.label}'
    out.mkdir(parents=True, exist_ok=False)
    print(out, flush=True)
    if exact_server_pids(port):
        raise RuntimeError(f'port {port} already has an isolated server')
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', port))
    if read('/sys/class/drm/card1/device/mem_info_vram_total') != str(30704 * MIB):
        raise RuntimeError('card1 VRAM identity changed')
    if Path('/sys/class/drm/card1/device').resolve().name != '0000:67:00.0':
        raise RuntimeError('card1 PCI identity changed')
    if Path('/sys/class/drm/card0/device').resolve().name != '0000:19:00.0':
        raise RuntimeError('card0 PCI identity changed')
    before = snapshot()
    if before['cards']['1']['vram_used_bytes'] > 1024 * MIB:
        raise RuntimeError('card1 is no longer free')
    start_temperature_c = max(before['cards']['1']['temperatures'].values()) / 1000
    if start_temperature_c > 30:
        raise RuntimeError(f'card1 is not cool enough for this arm: {start_temperature_c} C > 30 C')
    if subprocess.run(['systemctl', 'is-active', '--quiet', 'arctic-fan-watchdog.service']).returncode:
        raise RuntimeError('blower watchdog is not active')
    runtime_dir = os.environ.get('XDG_RUNTIME_DIR', '/run/user/1000')
    bus = os.environ.get('DBUS_SESSION_BUS_ADDRESS', f'unix:path={runtime_dir}/bus')
    unit_env = os.environ.copy()
    unit_env.update(XDG_RUNTIME_DIR=runtime_dir, DBUS_SESSION_BUS_ADDRESS=bus)
    state = subprocess.run(['systemctl', '--user', 'is-active', 'inferference-router.service'],
                           env=unit_env, capture_output=True, text=True)
    if state.stdout.strip() != 'inactive':
        raise RuntimeError(f'production router must be stopped: {state.stdout.strip() or state.stderr.strip()}')
    expected = {'performance_level': args.expected_performance_level,
                'profile_index': args.expected_profile, 'offset_mv': args.expected_offset_mv}
    if before['cards']['1']['controls'] != expected:
        raise RuntimeError(f'card1 controls differ from requested arm: {before["cards"]["1"]["controls"]} != {expected}')
    if not SERVER.is_file() or not MODEL.is_file():
        raise RuntimeError('server or model file is missing')
    actual_sha = model_sha256()
    if actual_sha != EXPECTED_SHA256:
        raise RuntimeError(f'model checksum changed: {actual_sha}')
    save_json(out / 'before.json', before)
    save_json(out / 'build-manifest.json', json.loads((SERVER_DIR / 'build-manifest.json').read_text()))
    (out / 'model-sha256.txt').write_text(f'{actual_sha}  {MODEL}\n')
    version = subprocess.run([str(SERVER), '--version'], capture_output=True, text=True, check=False)
    (out / 'server-version.txt').write_text(version.stdout + version.stderr)
    command = [str(SERVER), '--model', str(MODEL), '--host', '127.0.0.1', '--port', str(port),
               '--device', 'Vulkan0', '--split-mode', 'none', '--n-gpu-layers', '999', '--fit', 'off',
               '--ctx-size', str(ctx), '--parallel', str(parallel), '--batch-size', '1024',
               '--ubatch-size', '1024', '--flash-attn', 'auto', '--cache-type-k', 'q8_0',
               '--cache-type-v', 'q8_0', '--alias', 'qwen38-27b', '--jinja', '--log-verbosity', '5']
    wrapped = [str(REPO / 'ci/runner/gpu-lease.sh'), '24000', '--',
               str(REPO / 'ci/runner/gpu-thermal-guard.sh'), 'run', '--', *command]
    env = os.environ.copy()
    env.update({'GPU_LEASE_CARDS': '1', 'GPU_LEASE_TIMEOUT': '30', 'GPU_LEASE_POLL': '1'})
    save_json(out / 'resolved-command.json', {'utc': utc(), 'argv': wrapped,
                                              'environment': {k: env[k] for k in ('GPU_LEASE_CARDS', 'GPU_LEASE_TIMEOUT', 'GPU_LEASE_POLL')},
                                              'expected_card': 1, 'expected_pci': '0000:67:00.0',
                                              'expected_controls': expected})
    stop = threading.Event()
    spill = threading.Event()
    thermal_stop = threading.Event()
    samples = []

    def monitor():
        with (out / 'telemetry.jsonl').open('w') as stream:
            while not stop.is_set():
                try:
                    point = snapshot()
                    samples.append(point)
                    stream.write(json.dumps(point) + '\n')
                    stream.flush()
                    delta = point['cards']['1']['gtt_used_bytes'] - before['cards']['1']['gtt_used_bytes']
                    if delta > 512 * MIB:
                        spill.set()
                        save_json(out / 'gtt-abort.json', {'utc': utc(), 'delta_bytes': delta,
                                                            'killed_pids': stop_exact_server(port, signal.SIGKILL)})
                        return
                    hottest_c = max(v for card in point['cards'].values()
                                    for v in card['temperatures'].values()) / 1000
                    if hottest_c >= EXPERIMENT_STOP_C:
                        thermal_stop.set()
                        save_json(out / 'experiment-thermal-stop.json',
                                  {'utc': utc(), 'hottest_c': hottest_c,
                                   'stop_c': EXPERIMENT_STOP_C,
                                   'repository_guard_c': 80,
                                   'killed_pids': stop_exact_server(port, signal.SIGKILL)})
                        return
                except Exception as exc:
                    (out / 'monitor-error.txt').write_text(repr(exc) + '\n')
                    stop_exact_server(port, signal.SIGKILL)
                    return
                stop.wait(0.25)

    results = {}
    with (out / 'stdout-stderr.log').open('w') as log:
        process = subprocess.Popen(wrapped, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT)
        thread = threading.Thread(target=monitor, daemon=True)
        thread.start()
        try:
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline and process.poll() is None and not spill.is_set():
                try:
                    health = api(port, '/health', timeout=3)
                    if health['status'] == 200:
                        results['health'] = health
                        break
                except (URLError, TimeoutError):
                    pass
                time.sleep(1)
            else:
                raise RuntimeError('server did not become healthy within 120s or exited')
            results['models'] = api(port, '/v1/models', timeout=10)
            results['slots'] = api(port, '/slots', timeout=10)
            if args.label == 'power-saving-soak':
                started = time.monotonic()
                results['soak'] = {'started_utc': utc(), 'target_seconds': SOAK_SECONDS,
                                   'cycles': [], 'minimum_prompt_tokens': SOAK_MIN_PROMPT_TOKENS,
                                   'minimum_completion_tokens': SOAK_MIN_COMPLETION_TOKENS,
                                   'minimum_reasoning_tokens': SOAK_MIN_REASONING_TOKENS,
                                   'minimum_reasoning_characters': SOAK_MIN_REASONING_CHARACTERS}
                while time.monotonic() - started < SOAK_SECONDS:
                    cycle = len(results['soak']['cycles']) + 1
                    name = f'soak-{cycle:03d}'
                    payload = soak_request(cycle)
                    save_json(out / f'{name}-request.json', payload)
                    cycle_started_utc = utc()
                    response = api(port, '/v1/chat/completions', payload, timeout=600)
                    save_json(out / f'{name}-response.json', response)
                    checked = validate_soak(response)
                    checked.update(cycle=cycle, started_utc=cycle_started_utc, finished_utc=utc())
                    results['soak']['cycles'].append(checked)
                    results['soak']['elapsed_seconds'] = time.monotonic() - started
                    save_json(out / 'progress.json', results)
                    print(f'{name}: {json.dumps(checked)}', flush=True)
                    if not checked['ok']:
                        raise RuntimeError(f'{name} did not meet the long prompt and thinking checks')
                results['soak']['finished_utc'] = utc()
                results['soak']['elapsed_seconds'] = time.monotonic() - started
                results['soak']['completed_cycles'] = len(results['soak']['cycles'])
                results['soak']['total_prompt_tokens'] = sum(
                    x['usage']['prompt_tokens'] for x in results['soak']['cycles'])
                results['soak']['total_completion_tokens'] = sum(
                    x['usage']['completion_tokens'] for x in results['soak']['cycles'])
            else:
                for name, payload in request_cases():
                    save_json(out / f'{name}-request.json', payload)
                    response = api(port, '/v1/chat/completions', payload, timeout=300)
                    save_json(out / f'{name}-response.json', response)
                    results[name] = validate(name, response)
                    save_json(out / 'progress.json', results)
                    if not results[name]['ok']:
                        raise RuntimeError(f'{name} request validation failed: {results[name]}')
        except Exception as exc:
            results['failure'] = repr(exc)
        finally:
            stop_exact_server(port)
            try:
                results['supervisor_exit'] = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                stop_exact_server(port, signal.SIGKILL)
                results['supervisor_exit'] = process.wait(timeout=10)
            stop.set()
            thread.join(timeout=3)
    release_deadline = time.monotonic() + 30
    while time.monotonic() < release_deadline:
        if int(read('/sys/class/drm/card1/device/mem_info_vram_used')) < 1024 * MIB:
            break
        time.sleep(0.5)
    after = snapshot()
    save_json(out / 'after.json', after)
    results['spill_abort'] = spill.is_set()
    results['experiment_thermal_stop'] = thermal_stop.is_set()
    results['experiment_stop_c'] = EXPERIMENT_STOP_C
    results['vram_released'] = after['cards']['1']['vram_used_bytes'] < 1024 * MIB
    if samples:
        results['peak_card1_vram_mib'] = max(x['cards']['1']['vram_used_bytes'] for x in samples) / MIB
        results['peak_card1_gtt_delta_mib'] = (max(x['cards']['1']['gtt_used_bytes'] for x in samples) - before['cards']['1']['gtt_used_bytes']) / MIB
        results['peak_card1_power_w'] = max(int(x['cards']['1']['power_uw']) for x in samples) / 1e6
        results['peak_temperature_c'] = max(v for x in samples for card in x['cards'].values() for v in card['temperatures'].values()) / 1000
        results['peak_fan_rpm'] = max(int(x['fan']['fan1_rpm']) for x in samples)
    log_text = (out / 'stdout-stderr.log').read_text(errors='replace')
    results['flash_attention_log'] = [line for line in log_text.splitlines() if 'flash' in line.lower() and 'attn' in line.lower()][:20]
    results['cache_log'] = [line for line in log_text.splitlines() if 'KV buffer' in line or 'cache type' in line.lower()][:20]
    results['placement_log'] = [line for line in log_text.splitlines() if 'assigned to device' in line or 'offload' in line.lower()][:80]
    results['placement_ok'] = 'offloaded 66/66 layers to GPU' in log_text and results.get('peak_card1_vram_mib', 0) > 17000
    passed_requests = (results.get('soak', {}).get('elapsed_seconds', 0) >= SOAK_SECONDS
                       and results.get('soak', {}).get('completed_cycles', 0) >= 2
                       and all(x['ok'] for x in results.get('soak', {}).get('cycles', []))) \
        if args.label == 'power-saving-soak' else all(results.get(x, {}).get('ok') for x in ('prompt', 'decode'))
    passed = (passed_requests and results['placement_ok'] and results['vram_released']
              and not spill.is_set() and not thermal_stop.is_set()
              and 'failure' not in results and not (out / 'monitor-error.txt').exists())
    results['passed'] = passed
    save_json(out / 'summary.json', results)
    print(json.dumps({'artifact': str(out), 'summary': str(out / 'summary.json'),
                      'passed': passed,
                      'soak_cycles': results.get('soak', {}).get('completed_cycles'),
                      'soak_elapsed_seconds': results.get('soak', {}).get('elapsed_seconds'),
                      'prompt_tokens_per_second': results.get('prompt', {}).get('timings', {}).get('prompt_per_second'),
                      'thermal_stop': results['experiment_thermal_stop'],
                      'peak_temperature_c': results.get('peak_temperature_c'),
                      'peak_card1_power_w': results.get('peak_card1_power_w'),
                      'peak_fan_rpm': results.get('peak_fan_rpm'),
                      'vram_released': results['vram_released']}, indent=2), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
