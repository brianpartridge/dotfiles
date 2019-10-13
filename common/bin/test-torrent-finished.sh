#!/bin/bash

export TR_APP_VERSION=1
export TR_TORRENT_DIR=/var/tmp
export TR_TORRENT_HASH=abc
export TR_TORRENT_ID=123
export TR_TORRENT_NAME="test torrent"

./torrent-finished.rb

