# dotfiles

## Description

These are my dotfiles for work and play environments.  Files are organized into directories by config.

- common: Files common to all environments.
- work
- home-laptop
- home-server: Also holds the media scripts in `bin`, the Transmission web UI in `web` and the Apache config in `conf`.

#### Note:
If a config needs to extend a common file, consider putting the common settings into common and sourcing in the config specific settings from another file.

For example, each config can have a .bash\_profile\_ex file which will be sourced in by the common .bash\_profile file if one is found.

## Usage

- Clone to ~/dotfiles.

        git clone git@github.com:brianpartridge/dotfiles.git ~/dotfiles

- Run the install script with a config. It installs the tools in the Brewfiles, then links common and that config.

        ~/dotfiles/install.sh home-laptop

    Each top-level folder except common is a config. Use `none` to link only common. With no config, the script shows the configs and how to install one.

    The script installs Homebrew if it is not installed. It downloads the signed Homebrew package for the version in `install.sh`. Before it installs the package, it checks the checksum, the Developer ID team and the Apple notarization. To change the Homebrew version, change `HOMEBREW_VERSION` and `HOMEBREW_PKG_SHA256` in `install.sh`. Then it runs `brew bundle` on `common/Brewfile` and on the Brewfile of the config, if the config has one. Use `--no-brew` to skip these steps, for example `~/dotfiles/install.sh --no-brew home-laptop`.

    After it links the dotfiles, the script applies the macOS settings in `common/macos-defaults.sh` and in the `macos-defaults.sh` file of the config, if the config has one. It changes a setting only when the value is different. It restarts Dock, Finder or SystemUIServer only when their settings changed. Use `--no-defaults` to skip this step.

    If a real file in your home folder blocks a link, the script removes it only when it is the same as the copy in dotfiles. If the file is different, the script stops and shows the difference.

    You can run the script again at any time. It restows each package, so it also removes old links to files that moved or that you deleted.

- To run stow yourself, run it from ~/dotfiles. The `.stowrc` file sets the target to `~` and ignores `.DS_Store` files and Brewfiles.

        cd ~/dotfiles && stow common home-laptop

- To add a macOS setting, add a `set_default` line to `common/macos-defaults.sh` or to a `macos-defaults.sh` file in one config. To find the domain and key, run `defaults read` before and after you change the setting in System Settings.

- To add a tool, add a line to `common/Brewfile` for all machines, or to the Brewfile of one config. To find installed tools that are not in a Brewfile, run `brew bundle cleanup --file=<Brewfile>`. It only shows them. Add `--force` to uninstall them.

- When a change is made in one environment, push it to the remote so other environments can sync up.

## License

MIT
