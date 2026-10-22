"""Make the HaikuPorts 'haiku' install scheme work for a Python whose prefix is
already /boot/system/non-packaged. The patch assumes prefix=/boot/system and
appends "non-packaged" itself, which doubles the path for pip installs.

usage: python3 fix-nonpackaged-scheme.py <lib/python3.12 dir>
"""
import pathlib
import sys

lib = pathlib.Path(sys.argv[1])

sysconfig = lib / "sysconfig.py"
s = sysconfig.read_text()
old = """    'haiku': {
        'stdlib': '{installed_base}/lib/python{py_version_short}',
        'platstdlib': '{platbase}/lib/python{py_version_short}',
        'purelib': '{base}/non-packaged/lib/python{py_version_short}/site-packages',
        'platlib': '{platbase}/non-packaged/lib/python{py_version_short}/site-packages',
        'include': '{installed_base}/non-packaged/develop/headers/python{py_version_short}',
        'platinclude': '{installed_platbase}/develop/headers/python{py_version_short}',
        'scripts': '{base}/non-packaged/bin',
        'data'   : '{base}/non-packaged',
        },"""
new = """    'haiku': {
        'stdlib': '{installed_base}/lib/python{py_version_short}',
        'platstdlib': '{platbase}/lib/python{py_version_short}',
        'purelib': '{base}/lib/python{py_version_short}/site-packages',
        'platlib': '{platbase}/lib/python{py_version_short}/site-packages',
        'include': '{installed_base}/develop/headers/python{py_version_short}',
        'platinclude': '{installed_platbase}/develop/headers/python{py_version_short}',
        'scripts': '{base}/bin',
        'data'   : '{base}',
        },"""
if new not in s:
    assert s.count(old) == 1, "haiku scheme not found in sysconfig.py"
    sysconfig.write_text(s.replace(old, new))

site = lib / "site.py"
s = site.read_text()
old = """        if sys.platform.startswith('haiku'):
            # Locations under /system/
            sitepackages.append(os.path.join(prefix, "non-packaged", "lib","""
new = """        if sys.platform.startswith('haiku'):
            # Locations under /system/ (unless prefix already is non-packaged)
            if os.path.basename(prefix) != "non-packaged":
                sitepackages.append(os.path.join(prefix, "non-packaged", "lib","""
if new not in s:
    assert s.count(old) == 1, "haiku site-packages block not found in site.py"
    # re-indent the continuation lines of that append() call
    tail_old = """                                        "python%d.%d" % sys.version_info[:2],
                                        "site-packages"))
            sitepackages.append(os.path.join(prefix, "lib","""
    tail_new = """                                            "python%d.%d" % sys.version_info[:2],
                                            "site-packages"))
            sitepackages.append(os.path.join(prefix, "lib","""
    s = s.replace(old, new)
    assert s.count(tail_old) == 1, "site.py continuation lines not found"
    site.write_text(s.replace(tail_old, tail_new))

print("patched", sysconfig, site)
