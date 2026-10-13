#!/usr/bin/env python3
"""Codex transport adapter. The policy remains in the existing shared Bash hooks."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from transcript import load_records, normalize, tool_blocks

ROOT = Path(__file__).resolve().parents[2]
HOOKS = {'red-zone': 'red-zone-guard.sh', 'retro': 'retro-finding-gate.sh',
         'inventory': 'inventory-sync-guard.sh'}


def bash_path():
    if os.environ.get('SYSADMIN_BASH'):
        return os.environ['SYSADMIN_BASH']
    for name in ('bash', 'bash.exe'):
        found = shutil.which(name)
        if found and 'WindowsApps' not in found:
            return found
    for base in (os.environ.get('ProgramFiles', ''), os.environ.get('ProgramFiles(x86)', '')):
        candidate = Path(base) / 'Git/bin/bash.exe'
        if candidate.is_file():
            return str(candidate)
    raise RuntimeError('Нужен Bash: Git for Windows либо bash на macOS/Linux; задайте SYSADMIN_BASH.')


def blocked(reason):
    return {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                                  'permissionDecisionReason': reason}}


def run_shared(hook, payload):
    env = os.environ.copy()
    env['PYTHONIOENCODING'] = 'utf-8'
    env['SYSADMIN_PYTHON'] = sys.executable.replace('\\', '/')
    env['BASH_ENV'] = str(ROOT / 'scripts/runtime/hook-env.sh').replace('\\', '/')
    process = subprocess.run([bash_path(), str(ROOT / '.claude/hooks' / HOOKS[hook])],
                             input=json.dumps(payload, ensure_ascii=True),
                             text=True, encoding='utf-8', capture_output=True, env=env,
                             cwd=ROOT, timeout=12)
    if process.returncode:
        raise RuntimeError(f'Общий хук {HOOKS[hook]} завершился с кодом {process.returncode}.')
    raw = process.stdout.strip()
    if not raw:
        # A stderr failure with empty stdout is never silently interpreted as approval.
        if process.stderr.strip():
            raise RuntimeError(f'Общий хук {HOOKS[hook]} не доставил вердикт; проверь Python/Bash.')
        return None
    return json.loads(raw)


def dispatch(hook, payload):
    inp = payload.get('tool_input', {})
    if hook == 'retro':
        results = []
        for block in tool_blocks(payload.get('tool_name', ''), inp):
            mapped = dict(payload, tool_input=block['input'], tool_name=block['name'])
            result = run_shared(hook, mapped)
            if result:
                results.append(result)
        return results[0] if results else None
    mapped = dict(payload)
    if hook == 'red-zone':
        blocks = tool_blocks(payload.get('tool_name', 'Bash'), inp)
        mapped['tool_input'] = blocks[0]['input'] if blocks else {'command': json.dumps(inp)}
    mapped['session_id'] = 'codex:' + str(payload.get('session_id', ''))
    path = payload.get('transcript_path')
    # Never fall back to a Claude session with the same id.
    mapped['transcript_path'] = ''
    with tempfile.TemporaryDirectory(prefix='sysadmin-codex-hook-') as folder:
        if path and Path(path).is_file():
            records = normalize(load_records(path), runtime='codex')
            target = Path(folder) / 'normalized.jsonl'
            target.write_text(''.join(json.dumps(r, ensure_ascii=True) + '\n' for r in records), encoding='utf-8')
            mapped['transcript_path'] = str(target)
        return run_shared(hook, mapped)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('hook', choices=HOOKS)
    args = parser.parse_args()
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise ValueError('hook input must be an object')
        result = dispatch(args.hook, payload)
    except Exception as error:
        reason = f'Переходник Sysadmin/Codex не смог проверить действие: {error}'
        result = ({'systemMessage': reason} if args.hook == 'inventory' else blocked(reason))
    if result:
        # ASCII JSON is readable in every Windows code page, including startup failures.
        print(json.dumps(result, ensure_ascii=True))


if __name__ == '__main__':
    main()
