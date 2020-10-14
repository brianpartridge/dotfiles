# Configure up and down to search history based on input prefix
bindkey '\e[A' history-beginning-search-backward
bindkey '\e[B' history-beginning-search-forward

# rg (ripgrep) config
export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"
