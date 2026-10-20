#!/bin/bash

# install.sh: install git-flock, git-flock-commit, git-flock-autocommit and
# git-flock-guard (and optionally safegit).
#
#   sudo ./install.sh                       -> /usr/local/bin, for all users
#   ./install.sh ~/.local/bin               -> just you, no root needed
#   sudo ./install.sh --with-safegit        -> also install the safegit binary

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dest=/usr/local/bin
with_safegit=

for arg in "$@"; do
  case "$arg" in
    --with-safegit) with_safegit=1 ;;
    -h|--help) sed -n '3,9p' "$0"; exit 0 ;;
    *) dest="$arg" ;;
  esac
done

command -v git > /dev/null || { echo "git not found: dnf install git" >&2; exit 1; }
command -v flock > /dev/null || { echo "flock not found: dnf install util-linux" >&2; exit 1; }

mkdir -p "$dest"
install -m 0755 "$here/bin/git-flock" "$here/bin/git-flock-commit" "$here/bin/git-flock-autocommit" "$dest/"
install -m 0755 "$here/claude/block-raw-git.sh" "$dest/git-flock-guard"
echo "installed git-flock, git-flock-commit, git-flock-autocommit, git-flock-guard -> $dest"

if [[ -n "$with_safegit" ]]; then
  tarball=$(ls "$here"/vendor/safegit/safegit_*_linux_amd64.tar.gz | tail -n 1)
  (cd "$here/vendor/safegit" && sha256sum -c --ignore-missing checksums.txt)
  tar -xzf "$tarball" -C "$dest" safegit
  chmod 0755 "$dest/safegit"
  echo "installed safegit -> $dest ($("$dest/safegit" --version 2>&1 | head -n 1))"
fi

git_version=$(git --version | awk '{print $3}')
if [[ "$(printf '%s\n' 2.38.0 "$git_version" | sort -V | head -n 1)" != 2.38.0 ]]; then
  echo "note: git $git_version is older than 2.38; safegit's merge/cherry-pick/revert need 2.38-2.43 (commit is fine)"
fi

case ":$PATH:" in
  *":$dest:"*) ;;
  *) echo "note: $dest is not on PATH; add: export PATH=\"$dest:\$PATH\"" ;;
esac
