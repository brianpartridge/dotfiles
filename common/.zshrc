if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi

# Configure the prompt with git/VCS info and a right prompt with the date and time
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats '(%b) '
setopt PROMPT_SUBST
PROMPT='%F{cyan}%~%f%F{red}${vcs_info_msg_0_}%f$ '
RPROMPT='%F{green}%D{%m/%f/%y}|%D{%L:%M:%S}%f'

# Configure up and down to search history based on input prefix
bindkey '\e[A' history-beginning-search-backward
bindkey '\e[B' history-beginning-search-forward

# rg (ripgrep) config
export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"

# Cleans all Bazel created simulatores
function clean_bazel_sims() {
  local devices=($(xcrun simctl list -j | jq -r '.devices[] | map(select(.name | contains("New-") or contains("BAZEL_TEST")))[]?.udid'))
  echo "Cleaning ${#devices[@]} simulators"
  for device in "${devices[@]}"; do
    if ! xcrun simctl shutdown "$device"; then
      echo "Failed to shutdown $device, either it's already shutdown or it doesn't exist"
    fi

    if ! xcrun simctl delete "$device"; then
      echo "Failed to delete $device"
    fi
  done
}

# Bazel label Foo is actually a `ios_build_test` rule rather than the module Foo. Instead you want "Foo.lib". This does some sanitization of the input so it is easier to work with and callers do not need to remember the ".lib" suffix.
function bazel_sanitize_lib() {
    if [[ $1 != *Test && $1 != *DevApp ]]; then
        if [[ $1 != *.lib ]]; then
            echo "${1}.lib"
        else
            echo "$1"
        fi
    else
        echo "$1"
    fi
}

function lookup {
  if [[ "$1" == "//"* ]]; then
    echo $1
  else
    name=$(bazel_sanitize_lib $1)
    bazel query "filter(:$name$, //...)" --output=label
  fi
}

function dotgraph {
  label=$(lookup $1)
  depth="$2"
  query="deps($label, $depth)"
  if [[ -z "$depth" ]]; then
    query="deps($label)"
  fi
  timestamp=$(date +'%Y%m%d.%H%M%S')
  name=$(basename $1)
  tmpfile="$TMPDIR/$timestamp-graph-$name.dot"
  # Trim off the prefix for non-local labels
  # Extract the module name, dropping the path and an suffix
  bazel query --output graph --notool_deps "kind('(swift_library|.*_test\b)', $query)" | \
    perl -pe 's/\@swiftpkg\w+//g' | \
      perl -pe 's/\/\/[\w\/]*:([\w-]+)\b(\.\w*)?/$1/g' | \
        dot -Tdot > $tmpfile
  echo $tmpfile
}

function graph {
  dotfile=$(dotgraph $1 $2)
  echo $dotfile
  svgfile="$dotfile.svg"
  dot -Tsvg $dotfile > $svgfile
  echo $svgfile
  open $svgfile
}

function deps {
  label=$(lookup $1)
  local depth="$2"
  if [[ -z "$depth" ]]; then
    depth=1
  fi
  # Trim off the prefix for non-local labels
  # Extract the module name, dropping the path and an suffix
  bazel query "kind('(swift_library|.*_test\b)', $query)" | \
    perl -pe 's/\@swiftpkg\w+//g' | \
      perl -pe 's/\/\/[\w\/]*:([\w-]+)\b(\.\w*)?/$1/g'
}

function rdotgraph {
  label=$(lookup $1)
  local depth="$2"
  if [[ -z "$depth" ]]; then
    depth=1
  fi
  timestamp=$(date +'%Y%m%d.%H%M%S')
  name=$(basename $1)
  tmpfile="$TMPDIR/$timestamp-graph-$name.dot"
  # Trim off the prefix for non-local labels
  # Extract the module name, dropping the path and an suffix
  bazel query --output graph --notool_deps "kind('(swift_library|.*_test\b)', rdeps(//..., $label, $depth))" | \
    perl -pe 's/\@swiftpkg\w+//g' | \
      perl -pe 's/\/\/[\w\/]*:([\w-]+)\b(\.\w*)?/$1/g' | \
        dot -Tdot > $tmpfile
  echo $tmpfile
}

function rgraph {
  dotfile=$(rdotgraph $1 $2)
  echo $dotfile
  svgfile="$dotfile.svg"
  dot -Tsvg $dotfile > $svgfile
  echo $svgfile
  open $svgfile
}

function rdeps {
  label=$(lookup $1)
  local depth="$2"
  if [[ -z "$depth" ]]; then
    depth=1
  fi
  # Trim off the prefix for non-local labels
  # Extract the module name, dropping the path and an suffix
  bazel query "kind('(swift_library|.*_test\b)', rdeps(//..., $label, $depth))" | \
    perl -pe 's/\@swiftpkg\w+//g' | \
      perl -pe 's/\/\/[\w\/]*:([\w-]+)\b(\.\w*)?/$1/g'
}
