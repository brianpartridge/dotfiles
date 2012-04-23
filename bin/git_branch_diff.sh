#!/bin/bash

# Get the current branch name
gbn=`git branch --no-color 2> /dev/null | sed -e /^[^*]/d -e "s/* \(.*\)/\1/"`

# Diff current branch with master
git diff --full-index --ignore-submodules master $gbn > ~/Desktop/$gbn.diff