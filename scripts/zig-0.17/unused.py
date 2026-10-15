import re, sys
sys.path.insert(0, sys.argv[1]); from fields import body_span
HDR = re.compile(r'\|(\w+)_name, (\w+)_(type|value)(?:, (\w+)_attrs)?\|')
for f in sys.argv[2:]:
    s = open(f).read(); o = s; out = []; pos = 0
    for m in HDR.finditer(s):
        v = m.group(1); a, b = body_span(s, m.end()); body = s[a:b]
        caps = [f'{v}_name', f'{v}_{m.group(3)}'] + ([f'{v}_attrs'] if m.group(4) else [])
        caps = [c if re.search(rf'\b{c}\b', body) else '_' for c in caps]
        out.append(s[pos:m.start()]); out.append('|' + ', '.join(caps) + '|'); pos = m.end()
    out.append(s[pos:]); s = ''.join(out)
    if s != o: open(f, 'w').write(s); print(f)
