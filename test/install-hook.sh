#!/bin/sh
# Installs a git pre-commit hook that runs test/scan.sh and refuses the commit if it finds private data.
cd "$(dirname "$0")/.."
printf '#!/bin/sh\nexec sh test/scan.sh\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
echo "pre-commit hook installed"
