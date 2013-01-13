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

- Install GNU stow from Homebrew

        brew install stow
    
- Clone to ~/dotfiles, and enter the directory.

        cd ~/dotfiles
    
- Symlink the .file into place with stow. 

        stow --ignore ".DS_Store" common home-laptop 
    
- When a change is made in one environment, push it to the remote so other environments can sync up.

See rtrss-README.md for more info on using rtrss.py.

## License

None - Use them to make your life better.

## Contact

Brian Partridge - @brianpartridge on Twitter and alpha.app.net