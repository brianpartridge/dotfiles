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

# Configuration
TV_DIRECTORY = "/Volumes/Storage2/tv-freeform"
MOVIE_DIRECTORY = "/Volumes/Storage2/movies-misc"
LOGFILE = "~/logs/torrent-finished.log"
LOGLEVEL = logging.DEBUG

# DO NOT MODIFY BELOW THIS LINE #

class Torrent(object):
	name = ""
	hash = ""
	directory = ""
	
	mediaFilePath = ""
	
	def __init__(self):
		pass
		
	def path(self):
		return os.path.join(self.directory, self.name)
	
	def isTVShow(self):
		# TODO: regex the name check the directory to best guess the media type
		# set mediaFilePath
		return False
		
	def isMovie(self):
		# TODO: regex the name check the directory to best guess the media type
		# set mediaFilePath
		return False
		
	def createMediaLibraryCopy(self):
		if self.isTVShow():
			# copy mediaFilePath to TV_DIRECTORY
			logging.info("Copied to TV library.")
			pass
		elif self.isMovie():
			# copy mediaFilePath to MOVIE_DIRECTORY
			logging.info("Copied to movie library.")
			pass
		else:
			logging.info("Not valid for media library.")
	
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
			
		logging.info("name: %s" % self.name)
		logging.info("hash: %s" % self.hash)
		logging.info("directory: %s" % self.directory)
		logging.info("id: %s" % self.id)
		logging.info("version: %s" % self.appVersion)
		logging.info("time: %s" % self.time)
		logging.info("tv: %s" % self.isTVShow())
		logging.info("movie: %s" % self.isMovie())
		logging.info("path: %s" % self.path())
		pass
	
	

def main():
	logging.basicConfig(filename = os.path.expanduser(LOGFILE), level = LOGLEVEL, format='%(asctime)s [%(levelname)s] %(message)s', datefmt='%m/%d/%Y %I:%M:%S %p')
	logging.info("== STARTING ==")

	t = TransmissionTorrent()
	t.createMediaLibraryCopy()
	
	pass

if __name__ == "__main__":
	sys.exit(main())
	pass
