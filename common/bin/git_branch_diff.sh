#!/bin/bash

# Get the current branch name
gbn=`git branch --no-color 2> /dev/null | sed -e /^[^*]/d -e "s/* \(.*\)/\1/"`

# Diff current branch with main
git diff --full-index --ignore-submodules main $gbn > ~/Desktop/$gbn.diff