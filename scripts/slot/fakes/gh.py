#!/usr/bin/env python3
"""Stateful GitHub CLI substitute; unknown requests fail closed."""
import json
import os
from pathlib import Path
import sys

path = Path(os.environ['SLOT_GH_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
state.setdefault('calls', []).append(args)

def flag(name, default=None):
    return args[args.index(name) + 1] if name in args else default

answer = None
try:
    if args[0] == 'api':
        endpoint = next(a for a in args[1:] if a.startswith('repos/'))
        method = flag('--method', 'GET')
        fields = dict(args[i + 1].split('=', 1) for i, a in enumerate(args) if a == '-f')
        if endpoint.endswith('/dispatches'):
            state.setdefault('dispatches', []).append(json.load(sys.stdin))
        elif '/comments' in endpoint:
            comments = state.setdefault('comments', {}).setdefault(endpoint, [])
            if method == 'POST':
                comments.append({'body': fields['body']})
            answer = comments
        elif '/statuses/' in endpoint:
            statuses = state.setdefault('statuses', {}).setdefault(endpoint, [])
            if method == 'POST':
                statuses.append(fields)
            answer = statuses
        else:
            answer = state['objects'][endpoint]
    elif args[:2] == ['issue', 'edit']:
        endpoint = f'repos/{flag("--repo")}/issues/{args[2]}'
        labels = state['objects'][endpoint]['labels']
        if '--add-label' in args:
            labels.append({'name': flag('--add-label')})
        if '--remove-label' in args:
            labels[:] = [x for x in labels if x['name'] != flag('--remove-label')]
    elif args[:2] == ['issue', 'list']:
        answer = state.get('threads', [])
    elif args[:2] == ['pr', 'list']:
        answer = [p for p in state.get('prs', []) if p['branch'] == flag('--head')]
    elif args[:2] == ['pr', 'create']:
        state.setdefault('prs', []).append(dict(number=1, branch=flag('--head'), body=flag('--body')))
    elif args[:2] == ['pr', 'merge']:
        state['objects'][f'repos/{flag("--repo")}/pulls/{args[2]}']['auto_merge'] = True
    else:
        raise ValueError('unsupported fake gh command')
except (KeyError, ValueError) as error:
    path.write_text(json.dumps(state))
    sys.exit(str(error))
path.write_text(json.dumps(state))
print(json.dumps(answer))
