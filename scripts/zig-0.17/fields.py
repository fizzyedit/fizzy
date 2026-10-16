# rewrite `for (<fields-of-T>) |f| body` to 0.17's struct-of-arrays @typeInfo.
import re, sys
HDR = re.compile(r'(inline )?for \((?:std\.meta\.fields\(([^()]+)\)|(@typeInfo\([^()]+\)\.@"(struct|union|enum)")\.fields)\) \|(\w+)\|')
def body_span(s, i):
    # i: index just after the header; body is either a {...} block or a single statement to ';'
    j = i
    while s[j] == ' ': j += 1
    if s[j] == '{':
        d = 0
        for k in range(j, len(s)):
            if s[k] == '{': d += 1
            elif s[k] == '}':
                d -= 1
                if d == 0: return j, k + 1
    k = s.index(';', j); return j, k + 1
def conv(s):
    out = []; pos = 0
    for m in HDR.finditer(s):
        if m.start() < pos: continue
        inline, T, ti, kind, v = m.groups()
        info = ti if ti else f'@typeInfo({T}).@"struct"'
        kind = kind or 'struct'
        a, b = body_span(s, m.end()); body = s[a:b]
        if kind == 'enum' or re.search(rf'\b{v}\.value\b', body):
            if not ti: info = f'@typeInfo({T}).@"enum"'
            hdr = f'{inline or ""}for ({info}.field_names, {info}.field_values) |{v}_name, {v}_value|'
        else:
            hdr = f'{inline or ""}for ({info}.field_names, {info}.field_types, {info}.field_attrs) |{v}_name, {v}_type, {v}_attrs|'
        body = re.sub(rf'\b{v}\.name\b', f'{v}_name', body)
        body = re.sub(rf'\b{v}\.type\b', f'{v}_type', body)
        body = re.sub(rf'\b{v}\.value\b', f'{v}_value', body)
        body = re.sub(rf'\b{v}\.defaultValue\(\)', f'{v}_attrs.defaultValue({v}_type)', body)
        body = re.sub(rf'\b{v}\.default_value_ptr\b', f'{v}_attrs.default_value_ptr', body)
        body = re.sub(rf'\b{v}\.alignment\b', f'{v}_attrs.@"align"', body)
        body = re.sub(rf'\b{v}\.is_comptime\b', f'{v}_attrs.@"comptime"', body)
        out.append(s[pos:m.start()]); out.append(hdr); out.append(s[m.end():a]); out.append(body); pos = b
    out.append(s[pos:]); s = ''.join(out)
    s = re.sub(r'(@typeInfo\([^()]+\)\.@"(?:struct|union|enum)")\.fields\.len', r'\1.field_names.len', s)
    s = re.sub(r'std\.meta\.fields\(([^()]+)\)\.len', r'std.meta.fieldNames(\1).len', s)
    return s
if __name__ == '__main__':
  for f in sys.argv[1:]:
    s = open(f).read(); n = conv(s)
    if n != s: open(f, 'w').write(n); print(f)
