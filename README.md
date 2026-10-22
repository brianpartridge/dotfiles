# dotfiles

## Description

These are my dotfiles for work and play environments.  Files are organized into directories if they are location specific.

- common: Files common to all environments.
- work
- home-laptop
- home-server

#### Note:
If a specific location needs to extend a common file, consider putting the common settings into common and sourcing in the location specific settings from another file.

For example, each location can have a .bash\_profile\_ex file which will be sourced in by the common .bash\_profile file if one is found.

## Usage

- Clone to ~/dotfiles.

        git clone git@github.com:brianpartridge/dotfiles.git ~/dotfiles

- Run the install script. It asks which location to link. It always links common.

        ~/dotfiles/install.sh

    To skip the question, give the location as an argument, for example `~/dotfiles/install.sh home-laptop`. Use `none` to link only common.

    The script installs stow with Homebrew if stow is not installed. If a real file in your home folder blocks a link, the script removes it only when it is the same as the copy in dotfiles. If the file is different, the script stops and shows the difference.

    You can run the script again at any time.

- To run stow yourself, run it from ~/dotfiles. The `.stowrc` file sets the target to `~` and ignores `.DS_Store` files.

        cd ~/dotfiles && stow common home-laptop

- When a change is made in one environment, push it to the remote so other environments can sync up.

## License

MIT
