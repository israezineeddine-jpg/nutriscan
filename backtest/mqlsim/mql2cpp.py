import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
src = re.sub(r"C'(\d+),(\d+),(\d+)'", r"RGB(\1,\2,\3)", src)
out_lines = []
for line in src.split('\n'):
    st = line.strip()
    if st.startswith('#property'):
        continue
    if st.startswith('#define'):
        m = re.match(r'\s*#define\s+(\w+)\s+"(.*)"\s*$', line)
        if m:
            out_lines.append('#define %s _S("%s")' % (m.group(1), m.group(2)))
        else:
            out_lines.append(line)
        continue
    # walk the line: strip // comments, wrap string literals
    res = []; i = 0; n = len(line)
    while i < n:
        ch = line[i]
        if ch == '"':
            j = i + 1; buf = '"'
            while j < n and line[j] != '"':
                if line[j] == '\\' and j + 1 < n:
                    buf += line[j:j + 2]; j += 2
                else:
                    buf += line[j]; j += 1
            buf += '"'
            res.append('_S(%s)' % buf); i = j + 1
        elif ch == '/' and i + 1 < n and line[i + 1] == '/':
            break
        else:
            res.append(ch); i += 1
    out_lines.append(''.join(res))
code = '\n'.join(out_lines)
code = re.sub(r'^\s*input\s+', '', code, flags=re.M)
code = re.sub(r'((?:const\s+)?)(\w+)\s*&\s*(\w+)\s*\[\]', r'\1MArr<\2> &\3', code)
def decl(m):
    names = [x.strip()[:-2].strip() for x in m.group(2).split(',') if x.strip()]
    return 'MArr<%s> %s;' % (m.group(1), ', '.join(names))
code = re.sub(r'\b(datetime|double|int|bool|string|color|MqlRates)\s+((?:\w+\s*\[\]\s*,?\s*)+);', decl, code)
open(sys.argv[2], 'w', encoding='utf-8').write(code)
print('ok', sys.argv[2])
