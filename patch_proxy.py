import os, re, subprocess

PROXY = ‘/root/mysite/proxy/proxy.py’
os.makedirs(’/root/mysite/data/done’, exist_ok=True)

with open(PROXY, ‘r’) as f:
content = f.read()

if ‘done_diagnose’ in content:
print(‘Already patched.’)
else:
patched = False
for old in [
“if path == ‘/api/claude’: self.handle_claude()”,
‘if path == “/api/claude”: self.handle_claude()’,
]:
if old in content:
content = content.replace(
old,
old + “\n            elif path == ‘/api/done/diagnose’: self.handle_done_diagnose()\n            elif path == ‘/api/done/tasks’: self.handle_done_tasks()”
)
patched = True
print(‘Routes injected.’)
break

```
if not patched:
    content = re.sub(
        r'(self\.handle_claude\(\))',
        r"\1\n            elif path == '/api/done/diagnose': self.handle_done_diagnose()\n            elif path == '/api/done/tasks': self.handle_done_tasks()",
        content, count=1
    )
    print('Routes injected via fallback.')

new_methods = '''
def handle_done_diagnose(self):
    if not self.check_token(): return
    if not ANTHROPIC_KEY:
        self.send_json(500, {'error': 'no key'}); return
    try:
        import json as j, os as o, time as t
        from urllib.request import Request, urlopen
        data = j.loads(self.read_body())
        transcript = data.get('transcript', '').strip()
        pid = data.get('property_id', 'default')
        if not transcript:
            self.send_json(400, {'error': 'transcript required'}); return
        prompt = (
            'You are a home maintenance AI. A homeowner described a problem.\n\n'
            'Description: "' + transcript + '"\n\n'
            'Respond ONLY with raw JSON, no markdown fences.\n'
            'Use this exact structure:\n'
            '{"title":"short name","urgency":3,"urgency_label":"Address Soon","type":"DIY","diagnosis":"explanation here.","cost_min":100,"cost_max":500,"cost_note":"DIY materials","steps":["Step 1","Step 2","Step 3"],"safety_flag":false}'
        )
        body = j.dumps({
            'model': 'claude-haiku-4-5',
            'max_tokens': 1000,
            'messages': [{'role': 'user', 'content': prompt}]
        }).encode()
        req = Request(
            'https://api.anthropic.com/v1/messages',
            data=body,
            headers={
                'Content-Type': 'application/json',
                'x-api-key': ANTHROPIC_KEY,
                'anthropic-version': '2023-06-01'
            },
            method='POST'
        )
        with urlopen(req, timeout=60) as r:
            result = j.loads(r.read())
        raw = ''.join(b.get('text', '') for b in result.get('content', [])).strip()
        raw = raw.replace('```json', '').replace('```', '').strip()
        task = j.loads(raw)
        task['id'] = str(int(t.time() * 1000))
        task['transcript'] = transcript
        task['date'] = t.strftime('%Y-%m-%d')
        task['status'] = 'open'
        d = '/root/mysite/data/done/' + pid
        o.makedirs(d, exist_ok=True)
        with open(o.path.join(d, task['id'] + '.json'), 'w') as f:
            j.dump(task, f, indent=2)
        self.send_json(200, task)
    except Exception as e:
        self.send_json(500, {'error': str(e)})

def handle_done_tasks(self):
    if not self.check_token(): return
    try:
        import json as j, os as o
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        pid = qs.get('property_id', ['default'])[0]
        d = '/root/mysite/data/done/' + pid
        if self.command == 'GET':
            tasks = []
            if o.path.isdir(d):
                for fn in sorted(o.listdir(d), reverse=True):
                    if fn.endswith('.json'):
                        with open(o.path.join(d, fn)) as f:
                            tasks.append(j.load(f))
            self.send_json(200, {'tasks': tasks})
        elif self.command in ('POST', 'PATCH'):
            body = j.loads(self.read_body())
            fp = o.path.join(d, body.get('id', '') + '.json')
            if o.path.exists(fp):
                o.remove(fp)
            self.send_json(200, {'ok': True})
    except Exception as e:
        self.send_json(500, {'error': str(e)})
```

‘’’

```
content = content.replace(
    "if __name__ == '__main__':",
    new_methods + "if __name__ == '__main__':"
)

with open(PROXY, 'w') as f:
    f.write(content)
print('Proxy patched.')
```

subprocess.run([‘docker’, ‘compose’, ‘-f’, ‘/root/mysite/docker-compose.yml’, ‘restart’, ‘api-proxy’])
print(‘Done.’)