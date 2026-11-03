#!/usr/bin/env bash
#
# Install Homebrew and the tools in each Brewfile, link the common package
# and one config package into $HOME, then apply the macOS settings.
#
# Usage: ./install.sh [--no-brew] [--no-defaults] <config>
#
# With no config, the script shows the configs and how to install one.
# --no-brew skips the Brewfiles.
# --no-defaults skips the macos-defaults.sh files.

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOMEBREW_VERSION="7.0.10"
HOMEBREW_PKG_SHA256="ae13b8b0ac910730d3e982a9e7518288d17fd0ad272e42f412027e8ab4555575"
HOMEBREW_TEAM_ID="927JGANW46"
STOW_OPTS=(--dir "$DOTFILES" --target "$HOME" --ignore '\.DS_Store' --ignore 'Brewfile' --ignore 'macos-defaults\.sh')

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
  echo "Usage: $0 [--no-brew] [--no-defaults] <config>"
  echo
  echo "Installs the tools in each Brewfile, links common and the config you give,"
  echo "and applies the macOS settings in each macos-defaults.sh file."
  echo "--no-brew skips the Brewfiles. --no-defaults skips the macOS settings."
  echo
  echo "Configs:"
  while IFS= read -r config; do echo "  $config"; done < <(configs)
  echo "  none  (link only common)"
  echo
  echo "Example: $0 $(configs | head -n 1)"
}

# Load brew into this shell if Homebrew is installed.
load_homebrew() {
  command -v brew >/dev/null && return
  local brew
  for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$brew" ]] && eval "$("$brew" shellenv)" && return
  done
  return 1
}

# Install Homebrew from its signed package, not from a script piped to bash.
# The script stops if the checksum, signature or notarization is not correct.
# To update, change HOMEBREW_VERSION and HOMEBREW_PKG_SHA256. Get the checksum
# from the release page or from `shasum -a 256 Homebrew.pkg`.
install_homebrew() {
  load_homebrew && return

  if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install || true
    die "install the Xcode Command Line Tools in the window that opens, then run this script again"
  fi

  local tmp pkg signature
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # Expand $tmp now. It is local to this function.
  trap "rm -rf '$tmp'" EXIT
  pkg="$tmp/Homebrew-$HOMEBREW_VERSION.pkg"
  echo "Downloading Homebrew $HOMEBREW_VERSION."
  curl -fsSL -o "$pkg" \
    "https://github.com/Homebrew/brew/releases/download/$HOMEBREW_VERSION/Homebrew.pkg"

  [[ "$(shasum -a 256 "$pkg" | cut -d ' ' -f 1)" == "$HOMEBREW_PKG_SHA256" ]] ||
    die "the Homebrew package checksum is not correct"
  signature="$(pkgutil --check-signature "$pkg" || true)"
  [[ "$signature" == *"Developer ID Installer: "*"($HOMEBREW_TEAM_ID)"* ]] ||
    die "the Homebrew package is not signed by team $HOMEBREW_TEAM_ID"
  spctl --assess --type install "$pkg" 2>/dev/null ||
    die "macOS does not accept the Homebrew package. It may not be notarized."

  echo "Installing Homebrew. The installer asks for your password."
  sudo installer -pkg "$pkg" -target /

  load_homebrew || die "Homebrew installed, but brew is not in /opt/homebrew or /usr/local"
}

# Install the tools in the Brewfile of each package that has one.
install_brewfiles() {
  local pkg
  for pkg in "$@"; do
    [[ -f "$DOTFILES/$pkg/Brewfile" ]] || continue
    echo "Installing tools from $pkg/Brewfile."
    brew bundle install --file "$DOTFILES/$pkg/Brewfile"
  done
}

install_stow() {
  command -v stow >/dev/null && return
  install_homebrew
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

# Write one macOS setting, but only when its value is different.
# Usage: set_default <domain> <key> <-bool|-int|-float|-string> <value>
# The macos-defaults.sh files call this function.
set_default() {
  local domain="$1" key="$2" type="$3" value="$4" want current
  want="$value"
  if [[ "$type" == "-bool" ]]; then
    case "$value" in
      true | yes | 1) want=1 ;;
      *) want=0 ;;
    esac
  fi
  current="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  [[ "$current" == "$want" ]] && return
  echo "Setting $domain $key to $value."
  defaults write "$domain" "$key" "$type" "$value"
  case "$domain" in
    com.apple.dock) RESTART_APPS+=(Dock) ;;
    com.apple.finder) RESTART_APPS+=(Finder) ;;
    com.apple.screencapture) RESTART_APPS+=(SystemUIServer) ;;
  esac
}

# Apply the macos-defaults.sh file of each package that has one. Then
# restart the apps whose settings changed, so the new values take effect.
apply_defaults() {
  local pkg app
  RESTART_APPS=()
  for pkg in "$@"; do
    [[ -f "$DOTFILES/$pkg/macos-defaults.sh" ]] || continue
    echo "Applying macOS settings from $pkg/macos-defaults.sh."
    # shellcheck source=/dev/null
    source "$DOTFILES/$pkg/macos-defaults.sh"
  done
  [[ ${#RESTART_APPS[@]} -gt 0 ]] || return 0
  for app in $(printf '%s\n' "${RESTART_APPS[@]}" | sort -u); do
    echo "Restarting $app."
    killall "$app" 2>/dev/null || true
  done
  echo "Some settings take effect only after you log out and log in again."
}

main() {
  local brew=1 defaults=1 packages=(common)
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --no-brew) brew=0 ;;
      --no-defaults) defaults=0 ;;
      *) die "unknown option '$1'" ;;
    esac
    shift
  done
  local config="${1:-}"

  if [[ -z "$config" ]]; then
    usage
    exit 1
  fi
  if [[ "$config" != "none" ]]; then
    [[ -d "$DOTFILES/$config" && "$config" != "common" ]] ||
      die "unknown config '$config'. Use one of: $(configs | tr '\n' ' ')none"
    packages+=("$config")
  fi

  if [[ $brew -eq 1 ]]; then
    install_homebrew
    install_brewfiles "${packages[@]}"
  fi
  install_stow
  remove_duplicates "${packages[@]}"

  # Restow removes old links to files that are no longer in a package.
  # Restow one package at a time. With several packages, stow fails when
  # common owns a folded folder, such as ~/bin, that the config also has.
  local pkg
  for pkg in "${packages[@]}"; do
    echo "Linking: $pkg"
    stow --restow --verbose "${STOW_OPTS[@]}" "$pkg"
  done

  if [[ $defaults -eq 1 && "$(uname)" == "Darwin" ]]; then
    apply_defaults "${packages[@]}"
  fi
  echo "Done."
}

main "$@"
