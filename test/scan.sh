#!/bin/sh
# Fails when any file that would be committed names a shop, machine, person or private file.
# Runs in test/run.sh and as the pre-commit hook (test/install-hook.sh).
cd "$(dirname "$0")/.."
files=$(git ls-files --cached --others --exclude-standard 2>/dev/null || command find . -type f -not -path './.git/*')
pat='\bGR\b|grand rapids|renishaw|RENSP|GOPROBE|tools\.js|predator|MB ?Code|mbcode|\banvil\b|\bforge\b|mastercam|site\.lua|\bMJB\b|\bmatt|INGRSL|HCN8800|\bshop|\.SSB\b|\.LIB\b|[HU]:\\|#?\b(37[0-9]|38[0-9]|39[0-9]|45[0-9]|46[0-9]|47[0-9]|48[0-9]|341|875)\b'
bad=$(printf '%s\n' $files | sed 's|^\./||' | grep -v '^test/scan.sh$' | xargs -r grep -nIiE "$pat" 2>/dev/null)
for f in $files; do
  case "$f" in *.SSB|*.ssb|*.LIB|*.lib|*tools.js) bad="$bad
$f: private file type";; esac
done
if [ -n "$(printf '%s' "$bad" | tr -d '\n')" ]; then
  echo "scan: shop/machine data found:"; printf '%s\n' "$bad"; exit 1
fi
echo "scan: clean ($(printf '%s\n' $files | wc -l) files)"
