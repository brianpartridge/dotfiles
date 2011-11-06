#!/usr/bin/env python
# encoding: utf-8
"""
torrent-finished.py

Created by Brian Partridge.
Copyright (c) 2011 MultipleEntendre.com. All rights reserved.
"""

import sys
import os
import logging
import logging.handlers
import shutil
import re

# Configuration
MEDIA_ROOT = "/Volumes/DroboFS/tdb113070198/1/Public/media"
TV_DIRECTORY = os.path.join(MEDIA_ROOT, "tv-freeform")
MOVIE_DIRECTORY = os.path.join(MEDIA_ROOT, "movies-misc")
LOGFILE = "~/logs/torrent-finished.log"
LOGLEVEL = logging.DEBUG

# DO NOT MODIFY BELOW THIS LINE #

logger = logging.getLogger("torrent-finished logger")

def nameIsTVShow(name):
    # Old format: title delimiter s? number? delimiter? e? number delimiter
    # The problem with this regex is that it sometimes says movies are tv shows.
    # result = re.match(r'(.+)[\._ \-][Ss]?(\d+)?[\._ \-]?[EeXx]?(\d{2})[\._ \-]', self.name)
    
    # New format: title delimiter s number e number delimter
    # Its less powerful, but correct more often.
    result = re.match(r'(.+)[\._ \-][Ss](\d+)[EeXx](\d{2})[\._ \-]', name)
    if result:
        s_num = int(result.groups()[1])
        e_num = int(result.groups()[2])
        return True

    return False

def nameIsMovie(name):
    # Format: title delimiter 4digityear delimiter
    # Gets most things.  Should easily ignore junk that generally follows the year
    result = re.match(r'(.+)[\._ \-]((19|20)\d{2})[\._ \-]', name)
    if result:
        title = int(result.groups()[1])
        year = int(result.groups()[2])
        return True

    return False

class Torrent(object):
    name = ""
    hash = ""
    directory = ""
    mediaFilePath = None
    
    def __init__(self):
        pass
        
    def path(self):
        return os.path.join(self.directory, self.name)
    
    def isTVShow(self):
        return nameIsTVShow(self.name)
        
    def isMovie(self):
        return nameIsMovie(self.name)

    def resolveMediaFilePath(self):
        if self.mediaFilePath:
            return
        result = None
        target = self.path()
        mediaExtensions = [".mkv", ".avi", ".mov"]
        if os.path.isdir(target):
            # Search the directory for media files
            entries = os.listdir(target)
            potentialMediaFiles = []
            for e in entries:
                base, ext = os.path.splitext(e)
                if ext in mediaExtensions:
                    potentialMediaFiles.append(e) 
            mediaFileCount = len(potentialMediaFiles)
            if mediaFileCount == 1:
                result = os.path.join(target, potentialMediaFiles[0])
            else if mediaFileCount == 0:
                # No media files found, pass
                pass
            else:
                # TODO - filter out 'samples' so that the primary file can be found
                logger.debug("Too many media files (%d), unable to determine primary file." % len(potentialMediaFiles)
                pass
        else:
            base, ext = os.path.splitext(target)
            if ext in mediaExtensions:
                result = target
        self.mediaFilePath = result
        pass
        
    def createMediaLibraryCopy(self):
        dest = None
        if self.isTVShow():
            dest = TV_DIRECTORY
        elif self.isMovie():
            dest = MOVIE_DIRECTORY

        if not (self.mediaFilePath and dest):
            logger.debug("Not adding %s to media library", self.name)
			return

        if self.isMovie():
            path, mediaFileName = os.path.split(self.mediaFilePath)
            if not nameIsMovie(mediaFileName):
                logger.debug("This is a movie, but the media file needs to be renamed.")
                # The torrent was identified as a movie, but the mediafile was not
                # Create a new 'dest' with the torrent name
                base, ext = os.path.splitext(mediaFileName)
                newDestFileName = self.name + ext
                newDest = os.path.join(dest, newDestFileName)
                dest = newDest

        logger.info("Copying %s to %s" % (self.mediaFilePath, dest))
        try:
            shutil.copy(self.mediaFilePath, dest)
        except:
            logger.exception("Error while copying %s to %s" % (self.mediaFilePath, dest))
        else:
            logger.info("Copy complete")
            
        pass
    
class TransmissionTorrent(Torrent):
    appVersion = None
    time = None
    id = None
    
    def __init__(self):
        env = os.environ.copy()
        if 'TR_APP_VERSION' in env:
            self.appVersion = env['TR_APP_VERSION']
        if 'TR_TIME_LOCALTIME' in env:
            self.time = env['TR_TIME_LOCALTIME']
        if 'TR_TORRENT_DIR' in env:
            self.directory = env['TR_TORRENT_DIR']
        if 'TR_TORRENT_HASH' in env:
            self.hash = env['TR_TORRENT_HASH']
        if 'TR_TORRENT_ID' in env:
            self.id = env['TR_TORRENT_ID']
        if 'TR_TORRENT_NAME' in env:
            self.name = env['TR_TORRENT_NAME']

        self.resolveMediaFilePath()
            
        logger.info("name: %s" % self.name)
        logger.debug("hash: %s" % self.hash)
        logger.info("directory: %s" % self.directory)
        logger.debug("id: %s" % self.id)
        logger.debug("version: %s" % self.appVersion)
        logger.debug("time: %s" % self.time)
        logger.info("tv: %s" % self.isTVShow())
        logger.info("movie: %s" % self.isMovie())
        logger.info("path: %s" % self.path())
        logger.info("media: %s" % self.mediaFilePath)

        pass
    
def main():
    logger.setLevel(LOGLEVEL)

    filehandler = logging.handlers.RotatingFileHandler(os.path.expanduser(LOGFILE), maxBytes=10000, backupCount=5)
    filehandler.setLevel(logging.INFO)
    streamhandler = logging.StreamHandler(sys.stdout)
    streamhandler.setLevel(logging.DEBUG)
    
    formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", "%m/%d/%Y %I:%M:%S %p")
    filehandler.setFormatter(formatter)
    streamhandler.setFormatter(formatter)
    
    logger.addHandler(filehandler)
    logger.addHandler(streamhandler)
    
    logger.info("== STARTING ==")
    
    t = TransmissionTorrent()
    if not t.name:
        return
    t.createMediaLibraryCopy()

if __name__ == "__main__":
    sys.exit(main())
    pass
