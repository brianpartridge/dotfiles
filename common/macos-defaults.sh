# shellcheck shell=bash
# macOS settings for every config. install.sh sources this file and
# defines set_default. These values come from bp-mbp-silo.
#
# To find a setting, change it in System Settings, then compare the output
# of `defaults read` from before and after the change.

# Keyboard: move focus between all controls with Tab.
set_default NSGlobalDomain AppleKeyboardUIMode -int 2

# Appearance: use Dark mode.
set_default NSGlobalDomain AppleInterfaceStyle -string Dark

# Finder: show all file extensions, the status bar, and list view.
set_default NSGlobalDomain AppleShowAllExtensions -bool true
set_default com.apple.finder ShowStatusBar -bool true
set_default com.apple.finder FXPreferredViewStyle -string Nlsv
# New windows open Recents.
set_default com.apple.finder NewWindowTarget -string PfAF

# Dock: hide it automatically, use 44 point icons, and no bottom-right hot corner.
set_default com.apple.dock autohide -bool true
set_default com.apple.dock tilesize -int 44
set_default com.apple.dock wvous-br-corner -int 1
