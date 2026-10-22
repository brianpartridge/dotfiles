#!/usr/bin/env bash
#
# Install stow if needed, then link the common package and one location
# package into $HOME.
#
# Usage: ./install.sh [location]
#
# With no location, the script asks which one to use.

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STOW_OPTS=(--dir "$DOTFILES" --target "$HOME" --ignore '\.DS_Store')

die() {
  echo "error: $*" >&2
  exit 1
}

# Location packages are the top-level folders, except common.
locations() {
  local dir
  for dir in "$DOTFILES"/*/; do
    dir="$(basename "$dir")"
    [[ "$dir" == "common" ]] || echo "$dir"
  done
}

choose_location() {
  local options=() choice
  while IFS= read -r choice; do options+=("$choice"); done < <(locations)
  options+=("none")

  echo "Which location do you want to link with common?" >&2
  PS3="Location: "
  select choice in "${options[@]}"; do
    [[ -n "$choice" ]] && break
    echo "Type a number from the list." >&2
  done
  [[ -n "${choice:-}" ]] || die "no location selected"
  echo "$choice"
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
  local location="${1:-}" packages=(common)

  [[ -n "$location" ]] || location="$(choose_location)"
  if [[ "$location" != "none" ]]; then
    [[ -d "$DOTFILES/$location" && "$location" != "common" ]] ||
      die "unknown location '$location'. Use one of: $(locations | tr '\n' ' ')"
    packages+=("$location")
  fi

  install_stow
  remove_duplicates "${packages[@]}"

  echo "Linking: ${packages[*]}"
  stow --verbose "${STOW_OPTS[@]}" "${packages[@]}"
  echo "Done."
}

main "$@"
