# Colors
BLACK="\[\033[0;30m\]"
GREEN="\[\033[0;32m\]"
DARK_PURPLE="\[\033[0;34m\]"
CYAN="\[\033[0;36m\]"
RED="\[\033[0;31m\]"
PINK="\[\033[0;35m\]"
MUSTARD="\[\033[0;33m\]"
LIGHT_GRAY="\[\033[0;37m\]"
DARK_GRAY="\[\033[1;30m\]"
LIGHT_BLUE="\[\033[1;34m\]"
LIGHT_GREEN="\[\033[1;32m\]"
LIGHT_CYAN="\[\033[1;36m\]"
LIGHT_RED="\[\033[1;31m\]"
LIGHT_PURPLE="\[\033[1;35m\]"
YELLOW="\[\033[1;33m\]"
WHITE="\[\033[1;37m\]"
NO_COLOR="\[\033[0m\]"

# Conditionally load more settings
HOSTNAME=`hostname`
if [ "$HOSTNAME" = "nephthys" ]
then
	source ~/dotfiles/.bash_profile.nephthys
else
    if [ "$HOSTNAME" = "anubis.local" ]
    then
        source ~/dotfiles/.bash_profile.anubis
    else
	    source ~/dotfiles/.bash_profile.work
    fi
fi

# Show git branch in prompt
function parse_git_branch {
  git branch --no-color 2> /dev/null | sed -e '/^[^*]/d' -e "s/* \(.*\)/(\1)/"
}
GITPS1="$CYAN[$LIGHT_GRAY\W$CYAN]$GREEN\$(parse_git_branch)$RED\$$NO_COLOR "

# Configure the title of the terminal window
case $TERM in
  xterm*)
  TITLEBAR='\[\033]0;\u@\h\007\]'
  ;;
  *)
  TITLEBAR=""
  ;;
esac

# Apply the custom title and prompt values
PS1="${TITLEBAR}$GITPS1"

# Open a manpage in Preview
function pman {
	man -t "${1}" | open -f -a /Applications/Preview.app
}

# Open a manpage in the browser
function bman {
	man "${1}" | man2html | browser
}

# Aliases
alias g='git'
alias gd='git diff'
alias gdt='git difftool'
alias gl='git log'
alias glg='git lg'
alias gs='git status'
alias ls='ls -G'
alias ls-la='ls -laG'
alias cd..='cd ..'
alias grep='grep --color'
alias env='env | sort'
alias gitxa="gitx --all"
alias gitxc="gitx -c"

# Enable git bash completion
source `brew --prefix git`/etc/bash_completion.d/git-completion.bash
complete -o default -o nospace -F _git g
