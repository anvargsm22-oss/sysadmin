#!/usr/bin/env python3
"""Ask the installed local Codex loader to discover this project's skills/config.

No thread/turn is started, no model is called, and no trust or permission is changed.
Only project discovery counts are printed; user config and credentials are not printed.
"""
import json
import argparse
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parents[1]


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-active-hooks', action='store_true')
    args = parser.parse_args()
    cli = shutil.which('codex.cmd' if os.name == 'nt' else 'codex')
    if not cli:
        sys.exit('Codex CLI is not in PATH')
    process = subprocess.Popen([cli, 'app-server', '--strict-config'], cwd=ROOT,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding='utf-8',
                               creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    responses = queue.Queue()
    def read_stdout():
        for line in process.stdout:
            try:
                responses.put(json.loads(line))
            except ValueError:
                pass
        responses.put(None)
    # Drain stderr without exposing user-level settings or arbitrary diagnostics.
    threading.Thread(target=read_stdout, daemon=True).start()
    threading.Thread(target=lambda: process.stderr.read(), daemon=True).start()
    def send(obj):
        process.stdin.write(json.dumps(obj) + '\n')
        process.stdin.flush()
    def request(number, method, params):
        send({'jsonrpc': '2.0', 'id': number, 'method': method, 'params': params})
        while True:
            result = responses.get(timeout=30)
            if result is None:
                raise RuntimeError('Codex app-server stopped; inspect CLI config diagnostics locally')
            if result.get('id') == number:
                if 'error' in result:
                    raise RuntimeError(f'{method}: protocol error {result["error"].get("code")}')
                return result['result']
    try:
        request(1, 'initialize', {'clientInfo': {'name': 'sysadmin-runtime-check', 'version': '1.0'}})
        send({'jsonrpc': '2.0', 'method': 'initialized'})
        listed = request(2, 'skills/list', {'cwds': [str(ROOT)], 'forceReload': True})
        project = (ROOT / '.agents/skills').resolve()
        names, errors = set(), []
        for entry in listed.get('data', []):
            for skill in entry.get('skills', []):
                if Path(skill.get('path', '')).resolve().is_relative_to(project):
                    names.add(skill['name'])
            errors.extend(error for error in entry.get('errors', [])
                          if Path(error.get('path', '')).resolve().is_relative_to(project))
        expected = {p.parent.name for p in (ROOT / '.claude/skills').glob('*/SKILL.md')}
        missing = sorted(expected - names)
        config = request(3, 'config/read', {'cwd': str(ROOT), 'includeLayers': False}).get('config', {})
        hooks_enabled = config.get('features', {}).get('hooks')
        hooked = request(4, 'hooks/list', {'cwds': [str(ROOT)]})
        project_hooks = []
        hook_errors = []
        for entry in hooked.get('data', []):
            project_hooks.extend(h for h in entry.get('hooks', [])
                                 if Path(h.get('sourcePath', '')).resolve() == (ROOT / '.codex/hooks.json').resolve())
            hook_errors.extend(e for e in entry.get('errors', [])
                               if Path(e.get('path', '')).resolve().is_relative_to(ROOT / '.codex'))
        expected_hooks = sum(len(group['hooks']) for groups in
                             json.loads((ROOT / '.codex/hooks.json').read_text(encoding='utf-8'))['hooks'].values()
                             for group in groups)
        active = len(project_hooks) == expected_hooks and all(
            h.get('enabled') and h.get('trustStatus') in ('trusted', 'managed') for h in project_hooks)
        print(f'Installed Codex discovery: {len(names)}/{len(expected)} project skills; '
              f'errors={len(errors)}; hooks feature={hooks_enabled}')
        if missing:
            print('Missing: ' + ', '.join(missing))
        print(f'Project hook definitions: {len(project_hooks)}/{expected_hooks}; '
              f'errors={len(hook_errors)}; trusted+enabled={active}')
        print('Hook trust/activation is a separate check in /hooks; this probe does not grant trust.')
        return int(bool(missing or errors or hook_errors or hooks_enabled is not True or
                        len(project_hooks) != expected_hooks or (args.require_active_hooks and not active)))
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=10)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, queue.Empty) as error:
        sys.exit(f'Codex loader verification failed: {error}')
