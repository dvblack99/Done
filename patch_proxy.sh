#!/usr/bin/env python3
“””
Patches proxy.py to add Done app endpoints.
Run: python3 /root/patch_proxy.py
“””
import os, re, subprocess

PROXY = ‘/root/mysite/proxy/proxy.py’
DATA_DIR = ‘/root/mysite/data/done’

# 1. Create data directory

os.makedirs(DATA_DIR, exist_ok=True)
print(f”Created {DATA_DIR}”)

# 2. Read proxy

with open(PROXY, ‘r’) as f:
content = f.read()

if ‘done_diagnose’ in content:
print(“Already patched.”)
else:
# 3. Add routes
for old in [
“if path == ‘/api/claude’: self.handle_claude()”,
‘if path == “/api/claude”: self.handle_claude()’,
]:
if old in content:
new = old + “\n            elif path == ‘/api/done/diagnose’: self.handle_done_diagnose()\n            elif path == ‘/api/done/tasks’: self.handle_done_tasks()”
content = content.replace(old, new)
print(“Routes injected.”)
break
else:
# fallback: find handle_claude() call
content = re.sub(
r’(self.handle_claude())’,
r”\1\n            elif path == ‘/api/done/diagnose’: self.handle_done_diagnose()\n            elif path == ‘/api/done/tasks’: self.handle_done_tasks()”,
content, count=1
)
print(“Routes injected via fallback.”)

```
# 4. New handler methods
new_methods = r'''
def handle_done_diagnose(self):
    if not self.check_token(): return
    if not ANTHROPIC_KEY:
        self.send_json(500, {'error': 'ANTHROPIC_API_KEY not set'}); return
    try:
        import json as _j, os as _o, time as _t
        from urllib.request import Request, urlopen
        data = _j.loads(self.read_body())
        transcript = data.get('transcript', '').strip()
        property_id = data.get('property_id', 'default')
        if not transcript:
            self.send_json(400, {'error': 'transcript required'}); return

        prompt = (
            'You are a home maintenance AI assistant. A homeowner described a problem.\n\n'
            'Their description: "' + transcript + '"\n\n'
            'Respond ONLY with a valid JSON object. No preamble, no markdown fences. Raw JSON only.\n\n'
            '{\n'
            '  "title": "Short issue name (5 words max)",\n'
            '  "urgency": <1-5 integer, 5 = most urgent>,\n'
            '  "urgency_label": "One of: Low Priority / Monitor Soon / Address Soon / Urgent / Emergency",\n'
            '  "type": "One of: DIY / Hire Out / Either",\n'
            '  "diagnosis": "2-3 sentence plain English explanation.",\n'
            '  "cost_min": <integer dollars>,\n'
            '  "cost_max": <integer dollars>,\n'
            '  "cost_note": "Short note e.g. DIY materials only",\n'
            '  "steps": ["Step 1", "Step 2", "Step 3"],\n'
            '  "safety_flag": true or false\n'
            '}'
        )

        req_body = _j.dumps({
            'model': 'claude-haiku-4-5',
            'max_tokens': 1000,
            'messages': [{'role': 'user', 'content': prompt}]
        }).encode()

        req = Request(
            'https://api.anthropic.com/v1/messages',
            data=req_body,
            headers={
                'Content-Type': 'application/json',
                'x-api-key': ANTHROPIC_KEY,
                'anthropic-version': '2023-06-01'
            },
            method='POST'
        )
        with urlopen(req, timeout=60) as resp:
            result = _j.loads(resp.read())

        raw = ''.join(b.get('text', '') for b in result.get('content', [])).strip()
        raw = raw.replace('```json', '').replace('```', '').strip()
        task = _j.loads(raw)
        task['id'] = str(int(_t.time() * 1000))
        task['transcript'] = transcript
        task['date'] = _t.strftime('%Y-%m-%d')
        task['status'] = 'open'

        data_dir = '/root/mysite/data/done/' + property_id
        _o.makedirs(data_dir, exist_ok=True)
        with open(_o.path.join(data_dir, task['id'] + '.json'), 'w') as tf:
            _j.dump(task, tf, indent=2)

        self.send_json(200, task)
    except Exception as e:
        self.send_json(500, {'error': str(e)})

def handle_done_tasks(self):
    if not self.check_token(): return
    try:
        import json as _j, os as _o
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        property_id = qs.get('property_id', ['default'])[0]
        data_dir = '/root/mysite/data/done/' + property_id

        if self.command == 'GET':
            tasks = []
            if _o.path.isdir(data_dir):
                for fn in sorted(_o.listdir(data_dir), reverse=True):
                    if fn.endswith('.json'):
                        with open(_o.path.join(data_dir, fn)) as tf:
                            tasks.append(_j.load(tf))
            self.send_json(200, {'tasks': tasks})

        elif self.command in ('POST', 'PATCH'):
            body = _j.loads(self.read_body())
            task_id = body.get('id')
            task_file = _o.path.join(data_dir, task_id + '.json')
            if _o.path.exists(task_file):
                _o.remove(task_file)
            self.send_json(200, {'ok': True})
    except Exception as e:
        self.send_json(500, {'error': str(e)})
```

‘’’

```
# Insert before if __name__
content = content.replace(
    "if __name__ == '__main__':",
    new_methods + "if __name__ == '__main__':"
)

with open(PROXY, 'w') as f:
    f.write(content)
print("Proxy patched.")
```

# 5. Restart

print(“Restarting api-proxy…”)
subprocess.run([‘docker’, ‘compose’, ‘-f’, ‘/root/mysite/docker-compose.yml’, ‘restart’, ‘api-proxy’])
print(“Done.”)