#!/bin/bash
# Publish site/ to somedayx.com: the public priyank-saarthios-ai/somedayx-site
# repo, which GitHub Pages serves.
#
#   site/deploy.sh            # publish as is
#   site/deploy.sh --launch   # switch off pre-launch mode (install + GitHub links), then publish
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ "${1:-}" == "--launch" ]]; then
  sed -i '' 's/<body class="prelaunch">/<body>/' "$HERE/index.html"
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
gh repo clone priyank-saarthios-ai/somedayx-site "$TMP" -- -q
rsync -a --delete --exclude .git --exclude CNAME --exclude README.md --exclude deploy.sh "$HERE/" "$TMP/"
cd "$TMP"
git config user.name "$(git -C "$HERE" config user.name)"
git config user.email "$(git -C "$HERE" config user.email)"
git add -A
if git diff --cached --quiet; then echo "Nothing to publish."; exit 0; fi
git commit -qm "Update site"
git push -q
echo "Published. Live on somedayx.com in about a minute."
