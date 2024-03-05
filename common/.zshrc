# Configure up and down to search history based on input prefix
bindkey '\e[A' history-beginning-search-backward
bindkey '\e[B' history-beginning-search-forward

# rg (ripgrep) config
export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"

RPROMPT='%D{%m/%f/%y}|%D{%L:%M:%S}'

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

