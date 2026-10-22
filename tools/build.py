"""Copy the shared helpers from lib/common.ijm into every workflow macro.

Each macro = its own code, then MARKER, then the lib functions it calls (directly or through other lib functions).
Edit shared functions only in lib/common.ijm, then run:  python3 tools/build.py   (--check: only report stale files)
It also packs the workflows (and about/) into Confocal_Workflows.jar (menu: Plugins > Confocal Workflows) for one-file install.
"""
import glob, io, os, re, sys, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARKER = '// ======== shared functions: copied from lib/common.ijm by tools/build.py; edit them there, not here ========'


def lib_functions():
    lines = open(os.path.join(ROOT, 'lib', 'common.ijm')).read().split('\n')
    starts = [i for i, l in enumerate(lines) if l.startswith('function ')]
    funcs = {}
    for n, s in enumerate(starts):
        b = s
        while b > 0 and lines[b - 1].startswith('//'):
            b -= 1
        e = len(lines) if n + 1 == len(starts) else starts[n + 1]
        while e - 1 > s and (lines[e - 1].startswith('//') or not lines[e - 1].strip()):
            e -= 1
        funcs[re.match(r'function (\w+)', lines[s]).group(1)] = '\n'.join(lines[b:e]).rstrip() + '\n'
    return funcs


def needed(code, funcs):
    need, todo = set(), [code]
    while todo:
        text = todo.pop()
        for name in funcs:
            if name not in need and re.search(r'\b%s\s*\(' % name, text):
                need.add(name)
                todo.append(funcs[name])
    return need


def build(path, funcs):
    text = open(path).read()
    own = text.split(MARKER)[0].rstrip() + '\n'
    clash = set(re.findall(r'^function (\w+)', own, re.M)) & set(funcs)
    if clash:
        sys.exit('%s defines its own copy of %s: remove it (lib/common.ijm is the only copy)' % (path, ', '.join(sorted(clash))))
    need = needed(own, funcs)
    return own + '\n\n' + MARKER + '\n\n' + '\n'.join(funcs[n] for n in funcs if n in need)


def macros():
    """The workflows in menu order, About last."""
    return sorted(glob.glob(os.path.join(ROOT, '0*', '*.ijm'))) + sorted(glob.glob(os.path.join(ROOT, 'about', '*.ijm')))


def jar(paths):
    """Workflows + plugins.config as a jar; fixed timestamps so an unchanged build gives identical bytes."""
    names = [os.path.basename(p) for p in paths]
    config = ''.join('Plugins>Confocal Workflows, "%s", ij.plugin.Macro_Runner("JAR:%s")\n'
                     % (n[:-4].replace('_', ' '), n) for n in names)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in [('plugins.config', config)] + [(n, open(p).read()) for n, p in zip(names, paths)]:
            z.writestr(zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0)), data, zipfile.ZIP_DEFLATED)
    return buf.getvalue()


if __name__ == '__main__':
    funcs = lib_functions()
    stale = []
    for path in macros():
        new = build(path, funcs)
        if new != open(path).read():
            stale.append(os.path.relpath(path, ROOT))
            if '--check' not in sys.argv:
                open(path, 'w').write(new)
    paths = macros()
    jar_path = os.path.join(ROOT, 'Confocal_Workflows.jar')
    data = jar(paths)
    if not os.path.exists(jar_path) or open(jar_path, 'rb').read() != data:
        stale.append('Confocal_Workflows.jar')
        if '--check' not in sys.argv:
            open(jar_path, 'wb').write(data)
    print(('stale: ' if '--check' in sys.argv else 'rebuilt: ') + (', '.join(stale) or 'none'))
    sys.exit(1 if stale and '--check' in sys.argv else 0)
