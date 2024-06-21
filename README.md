# Git Metadata

Tracking metadata of binaries by git. In this context binaries are by definition all
files in the respective folder which are not tracked by git.

## Goal

Have a git history about changes in selected folders without tracking the respective binaries
by git. For instance, consider a folder of media files, then the particular changes of files
in this folder are uninteresting in general, but it is good to know that certain files
were added, moved or changed. In fact, this becomes more important when working in a multi client
environment with a remote backup since tracking of the respective metadata is sufficient
to know which file changed or moved and is newest.

## Files in this repository

* _DEBIAN/control_: the control file for the debian package
* _doc/*_: the manual
* _.gitignore_: files and patterns that should be ignored by git
* _build-debian.sh_: the script building the debian package
* _git-metadata.sh_: the main script executing git-metadata commands
* _LICENSE.txt_: the license
* _README.md_: this file

## Feature
### Advantages
* lightweight solution to have git-history of binary files
* works locally and supports independently remote git as well as remote binary repository
* git-metadata tool requires installation on client side only
* using rsync to push/pull to/from remote binary
* plenty of safety checks to avoid data loss or file duplications
* no file duplications in working and .git/ repository

### Limitations
* increased complexity because of split repository design
* single branch solution for binaries
* single version of binary files, there is no checkout of older version
* requires bash support on your system
* no auto resolve in divergent situations

## Building the debian package

Run the script from the root of this project
```shell
./build-debian.sh
```

The last git tag determines the version of the debian package and the tool.

## Install
Use the debian package for installation on debian based distributions.
```shell
sudo dpkg -i git-metadata-<version>_all.deb
```
The package is removed by
```shell
sudo dpkg -r git-metadata
```
For other distributions, the `alien` app may be useful to generate a suitable package from the
debian. It is also possible to download (git-metadata.sh, doc/*) and copy the relevant files
```shell
sudo cp git-metadata.sh /usr/local/bin/git-metadata
sudo asciidoctor -b manpage doc/git-metadata-man.ad -o - | gzip -c > /usr/local/share/man/man1/git-metadata.1.gz
```

## User manual

Available in the [doc](doc/index.ad) folder.

## Copyright

Copyright © 2024 Geometrie Profi.  License GPLv3+: GNU GPL version 3 or
later <https://gnu.org/licenses/gpl.html>. This is free software: you are free to
change and redistribute it. There is NO WARRANTY, to the extent permitted by law.
