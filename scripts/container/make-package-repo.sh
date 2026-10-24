#!/bin/bash
# Build a pkgman repository from the packages in /repo/out/packages (from
# build-core-tools.sh), in the layout Haiku's own repositories use:
#   repo.info     name/vendor/summary/priority/baseurl/identifier/architecture
#   repo          binary index (package_repo create), with each package's checksum
#   repo.sha256   sha256 of repo, hex + newline
#   packages/<file>.hpkg
#   index.html    landing page (package table from each hpkg's info)
# The output is a static site. Serve it at $BASEURL (GitHub Pages:
# bluevisor/haiku-arm64-packages), then on the guest:
#   pkgman add-repo $BASEURL
#
# Needs build-bfs-shell.sh's host tools (package_repo is built here if missing).
# Output: /repo/out/repo-site
set -euxo pipefail

BASEURL=${BASEURL:-https://bluevisor.github.io/haiku-arm64-packages}
SITE=/repo/out/repo-site
T=/build/haiku/generated/objects/linux/arm64/release/tools
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib

[ -x $T/package_repo/package_repo ] || (cd /build/haiku/generated && jam -q '<build>package_repo')

rm -rf $SITE && mkdir -p $SITE/packages
# package_repo rejects packages whose vendor differs from the repo's, so
# openssl3-3.5.9-1 (vendor "The OpenSSL Project") stays in the release only
cp /repo/out/packages/*.hpkg $SITE/packages/
cat > $SITE/repo.info <<EOF
name haiku-arm64-bootstrap
vendor "haiku-arm64-bootstrap"
summary "Extra packages for Haiku arm64 (github.com/bluevisor/haiku-arm64-bootstrap)"
priority 1
baseurl $BASEURL
identifier tag:bluevisor.github.io,2026:repositories/haiku-arm64-packages/arm64
architecture arm64
EOF
cd $SITE
$T/package_repo/package_repo create -q repo.info packages/*.hpkg
sha256sum repo | cut -d' ' -f1 > repo.sha256
touch .nojekyll

# Landing page: with .nojekyll, Pages serves no index for README.md, so / 404s
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
cat > index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>haiku-arm64-packages</title>
<style>
:root { --bg: #fff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea; --code: #f5f5f7; --link: #0b62c4; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #161618; --fg: #ececf0; --muted: #9a9aa2; --line: #2e2e33; --code: #222226; --link: #6aaeff; }
}
body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.5 -apple-system, system-ui, sans-serif; }
main { max-width: 960px; margin: 0 auto; padding: 32px 16px 48px; }
h1 { font-size: 24px; margin: 0 0 4px; }
p { margin: 8px 0; }
a { color: var(--link); }
.muted { color: var(--muted); }
pre, code { font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); border-radius: 6px; }
pre { padding: 12px 14px; overflow-x: auto; }
code { padding: 1px 5px; }
pre code { padding: 0; }
.scroll { overflow-x: auto; margin-top: 20px; }
table { border-collapse: collapse; width: 100%; font-size: 14px; }
th, td { text-align: left; padding: 7px 10px 7px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
th { font-weight: 600; color: var(--muted); }
td.n { white-space: nowrap; font-variant-numeric: tabular-nums; }
</style>
</head>
<body>
<main>
<h1>haiku-arm64-packages</h1>
EOF
cat >> index.html <<EOF
<p class="muted">A <code>pkgman</code> repository of extra packages for Haiku arm64 (hrev60290), built by
<a href="https://github.com/bluevisor/haiku-arm64-bootstrap">haiku-arm64-bootstrap</a>.</p>
<pre><code>pkgman add-repo $BASEURL
pkgman install ncurses6    # first: fixes the bootstrap terminfo path</code></pre>
<p><code>pkgman</code> needs HTTPS for this, which stock Haiku arm64 lacks: install <code>openssl3</code> and the
revision-8 <code>haiku</code>/<code>haiku_devel</code> packages from the
<a href="https://github.com/bluevisor/haiku-arm64-bootstrap/blob/main/docs/guide.md#11-pkgman-over-https">bootstrap release</a> first.
Per-package notes and sources: <a href="https://github.com/bluevisor/haiku-arm64-packages#readme">README</a>.</p>
<div class="scroll"><table>
<thead><tr><th>Package</th><th>Version</th><th>Summary</th><th>License</th><th>Size</th></tr></thead>
<tbody>
EOF
for f in packages/*.hpkg; do
  info=$($T/package/package list -i "$f")
  field() { sed -n "s/^\t$1: //p" <<<"$info"; }
  printf '<tr><td><a href="%s">%s</a></td><td class="n">%s</td><td>%s</td><td>%s</td><td class="n">%s</td></tr>\n' \
    "$f" "$(field name | esc)" "$(field version | esc)" "$(field summary | esc)" \
    "$(field license | paste -sd, - | sed 's/,/, /g' | esc)" \
    "$(stat -c %s "$f" | numfmt --to=iec-i --suffix=B)" >> index.html
done
cat >> index.html <<EOF
</tbody>
</table></div>
<p class="muted">$(ls packages/*.hpkg | wc -l) packages · arm64 only, zlib-compressed ·
<a href="repo.info">repo.info</a> · <a href="repo.sha256">repo.sha256</a></p>
</main>
</body>
</html>
EOF
$T/package_repo/package_repo list repo
ls -la $SITE $SITE/packages
