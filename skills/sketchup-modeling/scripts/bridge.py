#!/usr/bin/env python3
"""SketchUp bridge client; stdlib only, no automatic replay."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import time
import uuid

MAX_BYTES = 1_048_576
ID = re.compile(r'^[a-zA-Z0-9_-]{1,80}$')


class BridgeClient:
    def __init__(self, root):
        self.root = Path(root).absolute()

    def path(self, relative):
        parts = Path(relative).parts
        if not parts or Path(relative).is_absolute() or any(p in ('.', '..') for p in parts):
            raise ValueError('Unsafe relative path')
        result = self.root.joinpath(*parts)
        for p in (result, *result.parents):
            if p.is_symlink():
                raise ValueError('Symbolic links are not allowed: ' + str(p))
        return result

    def read(self, relative):
        with os.fdopen(os.open(self.path(relative), os.O_RDONLY | os.O_NOFOLLOW), 'rb') as f:
            data = f.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError('Response too large')
        return json.loads(data)

    def state(self, require_live=True):
        state = self.read('session.json')
        if state.get('protocol_version') != 1:
            raise ValueError('Unsupported bridge protocol')
        heartbeat = datetime.datetime.fromisoformat(state['heartbeat_at'].replace('Z', '+00:00'))
        age = (datetime.datetime.now(datetime.timezone.utc) - heartbeat).total_seconds()
        if require_live and (not state['enabled'] or age > 10):
            raise RuntimeError('Bridge disabled or heartbeat stale; an executing Ruby script may be blocking UI')
        return state

    def submit(self, action, arguments, request_id=None, expected_revision=None, model_token=None):
        state = self.state()
        request_id = request_id or str(uuid.uuid4())
        if not ID.fullmatch(request_id):
            raise ValueError('Invalid request_id')
        if not isinstance(arguments, dict):
            raise ValueError('arguments must be an object')
        if action not in state['capabilities']:
            raise ValueError('Action not in advertised capabilities')
        request = {
            'protocol_version': 1, 'request_id': request_id,
            'session_id': state['session_id'],
            'model_token': model_token if model_token is not None else state['model_token'],
            'expected_revision': expected_revision if expected_revision is not None else state['revision'],
            'action': action, 'arguments': arguments,
            'submitted_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        return self.submit_request(request)

    def submit_request(self, request):
        if not isinstance(request, dict) or not ID.fullmatch(request.get('request_id', '')):
            raise ValueError('Invalid request_id')
        blob = json.dumps(request, ensure_ascii=False, allow_nan=False).encode('utf-8')
        if len(blob) > MAX_BYTES:
            raise ValueError('Request exceeds 1 MiB')
        receipt = str(time.time_ns()) + '-' + str(uuid.uuid4())
        final = self.path('inbox/' + receipt + '.json')
        temp = self.path('inbox/' + receipt + '.tmp')
        try:
            with os.fdopen(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as f:
                f.write(blob)
                f.flush()
                os.fsync(f.fileno())
            os.replace(temp, final)
        finally:
            if temp.exists():
                temp.unlink()
        return {'request_id': request['request_id'], 'receipt': receipt, 'request': request}

    def result(self, request_id, receipt=None):
        if not ID.fullmatch(request_id):
            raise ValueError('Invalid request_id')
        if receipt:
            if not re.fullmatch(r'[a-zA-Z0-9_-]{1,100}', receipt):
                raise ValueError('Invalid receipt')
            rejection = 'rejections/' + receipt + '.json'
            if self.path(rejection).exists():
                return self.read(rejection)
        if receipt and any(self.path(d + '/' + receipt + '.json').exists() for d in ('inbox', 'processing')):
            return None
        relative = 'results/' + request_id + '.json'
        return self.read(relative) if self.path(relative).exists() else None

    def wait(self, request_id, receipt=None, timeout=30):
        deadline = time.monotonic() + timeout
        while True:
            result = self.result(request_id, receipt)
            if result is not None:
                return result
            if time.monotonic() >= deadline:
                raise TimeoutError('Outcome not known; query the SAME request_id. Do not replay with a new ID.')
            time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True)
    subs = parser.add_subparsers(dest='command', required=True)
    subs.add_parser('status')
    call = subs.add_parser('call')
    call.add_argument('action')
    call.add_argument('--args', default='{}')
    call.add_argument('--args-file')
    call.add_argument('--request-id')
    call.add_argument('--expected-revision', type=int)
    call.add_argument('--model-token')
    call.add_argument('--timeout', type=float, default=30)
    call.add_argument('--no-wait', action='store_true')
    submit = subs.add_parser('submit-file', help='Submit exact request for explicit retry or protocol testing')
    submit.add_argument('file')
    result = subs.add_parser('result')
    result.add_argument('request_id')
    result.add_argument('--receipt')
    result.add_argument('--timeout', type=float, default=0)
    args = parser.parse_args()
    client = BridgeClient(args.root)
    if args.command == 'status':
        output = client.state(require_live=False)
    elif args.command == 'submit-file':
        output = client.submit_request(json.loads(Path(args.file).read_text()))
    elif args.command == 'call':
        arguments = json.loads(Path(args.args_file).read_text()) if args.args_file else json.loads(args.args)
        submitted = client.submit(args.action, arguments, args.request_id, args.expected_revision, args.model_token)
        print(json.dumps(submitted, ensure_ascii=False), flush=True)
        if args.no_wait:
            return
        output = client.wait(submitted['request_id'], submitted['receipt'], args.timeout)
    else:
        output = client.wait(args.request_id, args.receipt, args.timeout)
    print(json.dumps(output, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, TimeoutError, OSError) as error:
        raise SystemExit(str(error))
