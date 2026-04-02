
#!/bin/bash

# Adds Done endpoints to existing proxy.py

# Run from: /root/mysite/proxy/

PROXY=”/root/mysite/proxy/proxy.py”

# 1. Create the done tasks storage directory

mkdir -p /root/mysite/data/done

# 2. Inject new route entries before the serve_forever line

# We insert into the routing block that dispatches handle_* methods

python3 - << ‘PYEOF’
import re

with open(’/root/mysite/proxy/proxy.py’, ‘r’) as f:
content = f.read()

# Check if already patched

if ‘done_diagnose’ in content:
print(“Already patched — skipping.”)
exit(0)

# Add routing: find the dispatch block and add new routes

# The proxy uses path matching like: if path == ‘/api/claude’: self.handle_claude()

# We add our two new routes the same way

old_route = “if path == ‘/api/claude’: self.handle_claude()”
new_route = “”“if path == ‘/api/claude’: self.handle_claude()
elif path == ‘/api/done/diagnose’: self.handle_done_diagnose()
elif path == ‘/api/done/tasks’: self.handle_done_tasks()”””

if old_route in content:
content = content.replace(old_route, new_route)
print(“Routes injected.”)
else:
# Fallback: find handle_claude call pattern
content = re.sub(
r”(handle_claude())”,
r”\1\n            elif path == ‘/api/done/diagnose’: self.handle_done_diagnose()\n            elif path == ‘/api/done/tasks’: self.handle_done_tasks()”,
content, count=1
)
print(“Routes injected via fallback.”)

# Add the two new handler methods before the final if **name** == ‘**main**’: block

new_methods = ‘’’
def handle_done_diagnose(self):
“”“Receive a transcript, call Claude Haiku, return structured diagnosis, save to disk.”””
if not self.check_token(): return
if not ANTHROPIC_KEY:
self.send_json(500, {‘error’: ‘ANTHROPIC_API_KEY not set’}); return
try:
import json as _json, os as _os, time as _time
data = _json.loads(self.read_body())
transcript = data.get(‘transcript’, ‘’).strip()
property_id = data.get(‘property_id’, ‘default’)
if not transcript:
self.send_json(400, {‘error’: ‘transcript required’}); return

```
        prompt = f"""You are a home maintenance AI assistant. A homeowner described a problem.
```

Their description: “{transcript}”

Respond ONLY with a valid JSON object. No preamble, no markdown fences. Raw JSON only.

{{
“title”: “Short issue name (5 words max)”,
“urgency”: <1-5 integer, 5 = most urgent>,
“urgency_label”: “One of: Low Priority / Monitor Soon / Address Soon / Urgent / Emergency”,
“type”: “One of: DIY / Hire Out / Either”,
“diagnosis”: “2-3 sentence plain English explanation of the problem and likely causes.”,
“cost_min”: <integer dollars>,
“cost_max”: <integer dollars>,
“cost_note”: “Short note e.g. DIY materials only or Licensed plumber required”,
“steps”: [“Step 1”, “Step 2”, “Step 3”],
“safety_flag”: true or false
}}”””

```
        req_body = _json.dumps({
            "model": "claude-haiku-4-5",
            "max_tokens": 1000,
            "messages": [{"role": "user", "content": prompt}]
        }).encode()

        from urllib.request import Request, urlopen
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
            result = _json.loads(resp.read())

        raw = ''.join(b.get('text','') for b in result.get('content',[])).strip()
        raw = raw.replace('```json','').replace('```','').strip()
        task = _json.loads(raw)
        task['id'] = str(int(_time.time() * 1000))
        task['transcript'] = transcript
        task['date'] = _time.strftime('%Y-%m-%d')
        task['status'] = 'open'

        # Save to disk
        data_dir = f'/root/mysite/data/done/{property_id}'
        _os.makedirs(data_dir, exist_ok=True)
        task_file = _os.path.join(data_dir, f"{task['id']}.json")
        with open(task_file, 'w') as tf:
            _json.dump(task, tf, indent=2)

        self.send_json(200, task)
    except Exception as e:
        self.send_json(500, {'error': str(e)})

def handle_done_tasks(self):
    """GET: return all tasks. PATCH: update a task status."""
    if not self.check_token(): return
    try:
        import json as _json, os as _os
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        property_id = qs.get('property_id', ['default'])[0]
        data_dir = f'/root/mysite/data/done/{property_id}'

        if self.command == 'GET':
            tasks = []
            if _os.path.isdir(data_dir):
                for fn in sorted(_os.listdir(data_dir), reverse=True):
                    if fn.endswith('.json'):
                        with open(_os.path.join(data_dir, fn)) as tf:
                            tasks.append(_json.load(tf))
            self.send_json(200, {'tasks': tasks})

        elif self.command in ('POST', 'PATCH'):
            body = _json.loads(self.read_body())
            action = body.get('action')  # 'done' or 'delete'
            task_id = body.get('id')
            task_file = _os.path.join(data_dir, f'{task_id}.json')

            if action == 'delete' or action == 'done':
                if _os.path.exists(task_file):
                    _os.remove(task_file)
                self.send_json(200, {'ok': True})
            else:
                self.send_json(400, {'error': 'unknown action'})
    except Exception as e:
        self.send_json(500, {'error': str(e)})
```

‘’’

# Insert before if **name**

content = content.replace(
“if **name** == ‘**main**’:”,
new_methods + “if **name** == ‘**main**’:”
)

with open(’/root/mysite/proxy/proxy.py’, ‘w’) as f:
f.write(content)

print(“Done. Proxy patched successfully.”)
PYEOF

# 3. Also handle OPTIONS for new routes (CORS preflight)

# The existing proxy likely already handles OPTIONS globally — no change needed.

# 4. Restart the proxy container

cd /root/mysite && docker compose restart api-proxy
echo “Proxy restarted.”

# 5. Verify

sleep 3
docker compose ps | grep api-proxy