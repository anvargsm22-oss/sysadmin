"""Normalize observed Claude JSONL and Codex rollout records without executing content.

Only event_msg/user_message is an operator message in a Codex root session.
response_item user messages also contain injected instructions and are never approvals.
Unknown formats produce no operator messages (the red guard then denies).
"""
import json
from pathlib import Path


def patch_edits(patch):
    """Return (path, added text) for apply_patch Add/Update/Move entries."""
    edits = []
    path, lines = None, []
    for line in patch.splitlines():
        if line.startswith(('*** Add File: ', '*** Update File: ', '*** Delete File: ')):
            if path is not None:
                edits.append((path, '\n'.join(lines)))
            path = line.split(': ', 1)[1]
            lines = []
        elif line.startswith('*** Move to: '):
            if path is not None:
                edits.append((path, '\n'.join(lines)))
            path = line.split(': ', 1)[1]
        elif path is not None and line.startswith('+'):
            lines.append(line[1:])
    if path is not None:
        edits.append((path, '\n'.join(lines)))
    return edits


def tool_blocks(name, value):
    """Map Codex tools to the common Claude-shaped hook input."""
    name = name.rsplit('.', 1)[-1]
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
            if isinstance(decoded, (dict, str)):
                value = decoded
        except ValueError:
            pass
    if name == 'apply_patch':
        patch = value if isinstance(value, str) else value.get('input', value.get('command', ''))
        return [{'type': 'tool_use', 'name': 'Edit',
                 'input': {'file_path': path, 'new_string': text}}
                for path, text in patch_edits(patch)]
    if name in ('exec_command', 'Bash', 'shell', 'exec', 'write_stdin'):
        if isinstance(value, dict):
            command = value.get('cmd', value.get('command', value.get('chars',
                      value.get('code', value.get('input', json.dumps(value))))))
        else:
            command = str(value)
        return [{'type': 'tool_use', 'name': 'Bash', 'input': {'command': command}}]
    if name in ('Write', 'Edit', 'NotebookEdit') and isinstance(value, dict):
        return [{'type': 'tool_use', 'name': name, 'input': value}]
    return [{'type': 'tool_use', 'name': name, 'input': value}]


def load_records(path):
    records = []
    with Path(path).open(encoding='utf-8-sig') as stream:
        for line in stream:
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if isinstance(item, dict):
                records.append(item)
    return records


def normalize(records, runtime='auto'):
    if runtime == 'auto':
        runtime = 'codex' if any(r.get('type') in ('session_meta', 'response_item', 'event_msg')
                                 for r in records) else 'claude'
    if runtime == 'claude':
        return records
    if runtime != 'codex':
        raise ValueError('Unknown runtime')
    child = any(r.get('type') == 'session_meta' and
                (r.get('payload', {}).get('parent_thread_id') or
                 r.get('payload', {}).get('forked_from_id') or
                 isinstance(r.get('payload', {}).get('source'), dict)) for r in records)
    output = []
    for record in records:
        payload = record.get('payload', {})
        if not isinstance(payload, dict):
            continue
        stamp = record.get('timestamp')
        if record.get('type') == 'event_msg' and payload.get('type') == 'user_message':
            text = payload.get('message')
            if isinstance(text, str):
                output.append({'type': 'user', 'timestamp': stamp, 'isSidechain': child,
                               'message': {'role': 'user', 'content': text}})
        elif record.get('type') == 'response_item':
            kind = payload.get('type')
            if kind in ('function_call', 'custom_tool_call'):
                value = payload.get('arguments', payload.get('input', ''))
                output.append({'type': 'assistant', 'timestamp': stamp,
                               'message': {'role': 'assistant', 'content':
                                           tool_blocks(payload.get('name', ''), value)}})
            elif kind == 'message' and payload.get('role') == 'assistant':
                blocks = [{'type': 'text', 'text': b.get('text', '')}
                          for b in payload.get('content', []) if isinstance(b, dict)
                          and b.get('type') in ('output_text', 'text')]
                output.append({'type': 'assistant', 'timestamp': stamp,
                               'message': {'role': 'assistant', 'content': blocks}})
            elif kind in ('function_call_output', 'custom_tool_call_output'):
                output.append({'type': 'user', 'timestamp': stamp, 'sourceToolUseID': payload.get('call_id'),
                               'message': {'role': 'user', 'content': [
                                   {'type': 'tool_result', 'content': str(payload.get('output', ''))}]}})
    return output
