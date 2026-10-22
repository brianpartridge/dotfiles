#!/usr/bin/env bash
#
# Install stow if needed, then link the common package and one config
# package into $HOME.
#
# Usage: ./install.sh <config>
#
# With no config, the script shows the configs and how to install one.

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STOW_OPTS=(--dir "$DOTFILES" --target "$HOME" --ignore '\.DS_Store')

die() {
  echo "error: $*" >&2
  exit 1
}

# Config packages are the top-level folders, except common.
configs() {
  local dir
  for dir in "$DOTFILES"/*/; do
    dir="$(basename "$dir")"
    [[ "$dir" == "common" ]] || echo "$dir"
  done
}

usage() {
  local config
  echo "Usage: $0 <config>"
  echo
  echo "Links common and the config you give. Configs:"
  while IFS= read -r config; do echo "  $config"; done < <(configs)
  echo "  none  (link only common)"
  echo
  echo "Example: $0 $(configs | head -n 1)"
}

install_stow() {
  command -v stow >/dev/null && return
  command -v brew >/dev/null ||
    die "Homebrew is not installed. Install it from https://brew.sh, then run this script again."
  echo "Installing stow with Homebrew."
  brew install stow
}

# Real files in $HOME block stow. Remove each one that is the same as the
# copy in dotfiles. Stop if any file is different, so no changes are lost.
remove_duplicates() {
  local output targets=() target pkg source found different=0
  output="$(stow --no "${STOW_OPTS[@]}" "$@" 2>&1)" && return

  while IFS= read -r target; do
    targets+=("$target")
  done < <(sed -n -E \
    -e 's/.*over existing target (.*) since neither a link nor a directory.*/\1/p' \
    -e 's/.*existing target is neither a link nor a directory: (.*)/\1/p' <<<"$output")

  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "$output" >&2
    die "stow found conflicts that this script does not fix"
  fi

  for target in "${targets[@]}"; do
    found=""
    for pkg in "$@"; do
      source="$DOTFILES/$pkg/$target"
      [[ -f "$source" ]] && found="$source" && break
    done
    if [[ -z "$found" ]]; then
      echo "$HOME/$target: no copy in dotfiles" >&2
      different=1
    elif ! cmp -s "$HOME/$target" "$found"; then
      echo "$HOME/$target is different from the copy in dotfiles:" >&2
      diff -u "$found" "$HOME/$target" >&2 || true
      different=1
    fi
  done
  [[ $different -eq 0 ]] ||
    die "move or merge the files above, then run this script again"

  for target in "${targets[@]}"; do
    echo "Removing $HOME/$target. It is the same as the copy in dotfiles."
    rm "$HOME/$target"
  done
}

main() {
  local config="${1:-}" packages=(common)

  if [[ -z "$config" ]]; then
    usage
    exit 1
  fi
  if [[ "$config" != "none" ]]; then
    [[ -d "$DOTFILES/$config" && "$config" != "common" ]] ||
      die "unknown config '$config'. Use one of: $(configs | tr '\n' ' ')none"
    packages+=("$config")
  fi

  install_stow
  remove_duplicates "${packages[@]}"

  echo "Linking: ${packages[*]}"
  stow --verbose "${STOW_OPTS[@]}" "${packages[@]}"
  echo "Done."
}

main "$@"
