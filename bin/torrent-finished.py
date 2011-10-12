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
import shutil
import re

# Configuration
MEDIA_ROOT = "/Volumes/DroboFS/tdb113070198/1/Public/media"
TV_DIRECTORY = os.path.join(MEDIA_ROOT, "tv-freeform")
MOVIE_DIRECTORY = os.path.join(MEDIA_ROOT, "movies-misc")
LOGFILE = "~/logs/torrent-finished.log"
LOGLEVEL = logging.DEBUG

# DO NOT MODIFY BELOW THIS LINE #

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
                # Old format: title delimiter s? number? delimiter? e? number delimiter
                # The problem with this regex is that it sometimes says movies are tv shows.
                # result = re.match(r'(.+)[\._ \-][Ss]?(\d+)?[\._ \-]?[EeXx]?(\d{2})[\._ \-]', self.name)
                
                # New format: title delimiter s number e number delimter
                # Its less powerful, but correct more often.
                result = re.match(r'(.+)[\._ \-][Ss](\d+)[EeXx](\d{2})[\._ \-]', self.name)
                if result:
                        s_num = int(result.groups()[1])
                        e_num = int(result.groups()[2])
			return True

		return False
		
	def isMovie(self):
		# TODO: regex the name check the directory to best guess the media type
		return False

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
			if len(potentialMediaFiles) == 1:
				result = os.path.join(target, potentialMediaFiles[0])
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

		if self.mediaFilePath and dest:
			logging.info("Copying %s to %s" % (self.mediaFilePath, dest))
			try:
				shutil.copy(self.mediaFilePath, dest)
			except:
				logging.exception("Error while copying %s to %s" % (self.mediaFilePath, dest))
			else:
				logging.info("Copy complete")
		else:
			logging.info("Not adding %s to media library", self.name)
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
			
		logging.info("name: %s" % self.name)
		logging.info("hash: %s" % self.hash)
		logging.info("directory: %s" % self.directory)
		logging.info("id: %s" % self.id)
		logging.info("version: %s" % self.appVersion)
		logging.info("time: %s" % self.time)
		logging.info("tv: %s" % self.isTVShow())
		logging.info("movie: %s" % self.isMovie())
		logging.info("path: %s" % self.path())
		logging.info("media: %s" % self.mediaFilePath)

		pass
	
def main():
	logging.basicConfig(filename = os.path.expanduser(LOGFILE), level = LOGLEVEL, format='%(asctime)s [%(levelname)s] %(message)s', datefmt='%m/%d/%Y %I:%M:%S %p')
	logging.info("== STARTING ==")
	
	t = TransmissionTorrent()
	if not t.name:
		return
	t.createMediaLibraryCopy()

if __name__ == "__main__":
	sys.exit(main())
	pass
