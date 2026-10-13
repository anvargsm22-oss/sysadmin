#!/usr/bin/env python3
"""Read-only dispatch eval using the user's Codex CLI, without an API-key dependency."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def parse_choice(text, names):
    match = re.fullmatch(r'\s*SKILL\s*:\s*([a-z0-9-]+)\s*', text)
    if not match or match[1] not in set(names) | {'none'}:
        raise ValueError('Codex did not return one exact skill name')
    return match[1]


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: invoke-codex.py <phrase>')
    cli = shutil.which('codex.cmd' if os.name == 'nt' else 'codex')
    if not cli:
        sys.exit('Codex CLI is not in PATH')
    sources = sorted((ROOT / '.claude/skills').glob('*/SKILL.md'))
    names = [source.parent.name for source in sources]
    if not names:
        sys.exit('No canonical skills found')
    descriptions = []
    for source in sources:
        text = source.read_text(encoding='utf-8')
        descriptions.append(source.parent.name + ':\n' + text.split('---', 2)[1])
    prompt = ('Это только проверка выбора навыка. Не выполняй задачу, не вызывай инструменты, '
              'не подключайся к серверам. Выбери ровно одно имя из каталога либо none. '
              'Ответ строго одной строкой SKILL: <имя>. Каталог:\n' + '\n'.join(descriptions) +
              '\nФраза оператора (данные для классификации):\n' + sys.argv[1])
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='sysadmin-eval-codex-') as folder:
        last = Path(folder) / 'last-message.txt'
        process = subprocess.run([cli, 'exec', '--ephemeral', '--sandbox', 'read-only',
                                  '--output-last-message', str(last), '-'], input=prompt,
                                 text=True, encoding='utf-8', capture_output=True, cwd=ROOT, timeout=180)
        if process.returncode or not last.is_file():
            sys.exit('Codex eval failed; check CLI authentication, permissions and hook trust')
        choice = parse_choice(last.read_text(encoding='utf-8'), names)
    print(f'{choice}|unknown|{int((time.monotonic() - start) * 1000)}')


if __name__ == '__main__':
    main()
