#!/bin/sh

/usr/bin/sed -i '.bak' 's/[[:space:]]*$//' `git ls-files --modified '*.[hm]'`
