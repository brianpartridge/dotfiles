#!/usr/bin/env python

"""
rtrss.py
Version 0.5

Copyright (c) 2012 Brian Partridge

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

"""

import feedparser
import re
import urllib
import os
import sys
import ConfigParser
import time
import logging
import logging.handlers

# Import t cli wrapper
import tweet

# Configuration
CONFIGFILE = "~/Dropbox/conf/rtrss.conf"
TORRENT_DIRECTORY = "~/rsstorrents"
LOGFILE = "~/logs/rtrss.log"
LOGLEVEL = logging.DEBUG

# DO NOT MODIFY BELOW THIS LINE #

logger = logging.getLogger("rtrss logger")

parsed_feeds = {}

class RtRssFault(Exception):
	def __init__(self, msg):
		self.msg = msg

##### Episodes #####

class Episode():
	def __init__(self, url, name):
		self.url = url
		self.name = name

	def displayName(self):
		return self.name
        
	def isValid(self):
		return True
        
	def Get(self):
		msg = "Getting: %s " % self.displayName()
		print msg
		logger.info(msg)

		tweet.tweet("START:Download - %s" % self.displayName())

		filename = os.path.join(os.path.expanduser(TORRENT_DIRECTORY), "%s rtRSS.torrent" % self.displayName())
		try:
			urllib.urlretrieve(self.url, filename)
		except IOError, e:
			logger.exception("Error retrieving torrent from: %s at: %s" % (self.url, filename))
            
	def __gt__(self, rhs):
		if self < rhs:
			return False
		if self == rhs:
			return False
		return True
    
class SeasonalEpisode(Episode):
	def __init__(self, url, name, season, episode):
		self.url = url
		self.name = name
		self.season = int(season)
		self.episode = int(episode)
		
	def displayName(self):
		return "%s S%02dE%02d" % (self.name, self.season, self.episode)
        
	def isValid(self):
		return (self.season != 0 and self.episode != 0)
			
	def __lt__(self, rhs):
		if self.season < rhs.season:
			return True
		elif self.season == rhs.season and self.episode < rhs.episode:
			return True
		return False
		
	def __eq__(self, rhs):
		if self.season == rhs.season and self.episode == rhs.episode:
			return True
		return False
        
class DatedEpisode(Episode):
	def __init__(self, url, name, year, month, day):
		self.url = url
		self.name = name
		self.year = int(year)
		self.month = int(month)
		self.day = int(day)
		
	def displayName(self):
		return "%s %04d-%02d-%02d" % (self.name, self.year, self.month, self.day)
			
	def isValid(self):
		return (self.year != 0 and self.month != 0 and self.day != 0)
        
	def __lt__(self, rhs):
		if self.year < rhs.year:
			return True
		elif self.year == rhs.year and self.month < rhs.month:
			return True
		elif self.year == rhs.year and self.month == rhs.month and self.day < rhs.day:
			return True
		return False
		
	def __eq__(self, rhs):
		if self.year == rhs.year and self.month == rhs.month and self.day == rhs.day:
			return True
		return False
        
##### Feeds #####

class TvFeed():
	def __init__(self, args):
		self.url = args['url']
		self.keywords = args['keywords']
		self.name = args['name']
		self.label = args['label']
        
	def episodeForEntry(self, entry):
		pass
        
	def ListEpisodes(self):
		logger.debug("Processing %s" % self.label)
		
		previously_cached = True
		# cache the parsed feed
		if not parsed_feeds.has_key(self.url):
			previously_cached = False
			logger.debug("Parsing: %s" % self.url)
			temp = feedparser.parse(self.url)
			parsed_feeds[self.url] = temp
			logger.debug("%d entries" % (len(temp.entries)))
		feed = parsed_feeds[self.url]
		
		eps = []
		for e in feed.entries:
			if not e.link:
				continue

			# print the feed entries if this is the first time with the feed
			if not previously_cached:
				 logger.debug("  %s" % e.title.encode("utf-8"))

			# check for keywords
			found = True
			for k in self.keywords:
				if k.lower() not in e.title.lower():
					found = False
					break
			if not found:
				# if any keywords weren't found, move on to the next entry
				continue
			logger.info("Found: %s" % e.title.encode("utf-8"))

			# Remove H.264 as it breaks my regular expression
			if "H.264" in e.title:
				e.title = e.title.replace("H.264", "")
			elif "h.264" in e.title:
				e.title = e.title.replace("h.264", "")
					
			ep = self.episodeForEntry(e)
			if ep is None:
				continue
			eps.append(ep)
			
			# next
		
		return eps
    
	def currentEpisode(self):
		return None

class SeasonalTvFeed(TvFeed):
	def __init__(self, args):
		self.url = args['url']
		self.keywords = args['keywords']
		self.name = args['name']
		self.label = args['label']
		self.last_season = args['season']
		self.last_episode = args['episode']
        
	def episodeForEntry(self, entry):
		ep = None
		if "Part" in self.keywords:
			# specific for series that use 'Parts' rather then episodes and don't have a season
			# get info from entry title
			result = re.match(r'.+[\._ \-]+Part (\d+)', entry.title)
			if result:
				ep = SeasonalEpisode(entry.link, self.name, 0, int(result.groups()[0]))
			else:
				# error nothing to compare against
				logger.debug("No part number found.")
		else:
			# get info from entry title
			result = re.match(r'(.+)[\._ \-][Ss]?(\d+)?[\._ \-]?[EeXx]?(\d{2})[\._ \-]', entry.title)
			if result:
				# if no season # was found default to 1
				# necessary for miniseries
				if result.groups()[1]:
					s_num = int(result.groups()[1])
				else:
					s_num = 1

				e_num = int(result.groups()[2])

				ep = SeasonalEpisode(entry.link, self.name, s_num, e_num)
			else:
				# error nothing to compare against
				logger.debug("No season/episode number found.")
		return ep
        
	def currentEpisode(self):
		return SeasonalEpisode(None, self.name, self.last_season, self.last_episode)
        
class DatedTvFeed(TvFeed):
	def __init__(self, args):
		self.url = args['url']
		self.keywords = args['keywords']
		self.name = args['name']
		self.label = args['label']
		self.last_year = args['year']
		self.last_month = args['month']
		self.last_day = args['day']
        
	def episodeForEntry(self, entry):
		ep = None
		# get info from entry title
		result = re.match(r'.+(\d{4})-(\d{2})-(\d{2})', entry.title)
		if result:
			year = int(result.groups()[0])
			month = int(result.groups()[1])
			day = int(result.groups()[2])
			ep = DatedEpisode(entry.link, self.name, year, month, day)
		else:
			# error nothing to compare against
			logger.debug("No date found.")
		return ep
        
	def currentEpisode(self):
		return DatedEpisode(None, self.name, self.last_year, self.last_month, self.last_day)
        
def feedForArgs(args):
	if args['type'] == 'dated':
		return DatedTvFeed(args)
	else:
		return SeasonalTvFeed(args)

def main(argv=None):
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
	
	cp = ConfigParser.ConfigParser()
	cp.read(os.path.expanduser(CONFIGFILE))
	
	for show in cp.sections():
		# initialize mandatory inputs
		args = {'label': show, 'url': None, 'name':None, 'keywords': [], 'type':'seasonal', 'season':0, 'episode':0, 'year':0, 'month':0, 'day':0}
		
		# populate args
		for key in args.keys():
			if cp.has_option(show, key):
				args[key] = cp.get(show, key)
	
		# verify that there is a url        
		if not args.has_key('url'):
			raise RtRssFault('no url for %s' % (show,))
		
		# split the keywords
		if args['keywords']:
			args['keywords'] = args['keywords'].split()
		else:
			keywords = []
		feed = feedForArgs(args)
	
		# retrieve all episodes in the feed
		eps = feed.ListEpisodes()

		# remove duplicates and invalid episodes
		final_eps = []
		for ep in eps:
			if not ep.isValid():
				continue
			if ep not in final_eps:
				final_eps.append(ep)
                
		# identify the last retrieved episode
		currentEp = feed.currentEpisode()
			
		# iterate over the eps and load new eps
		latestEp = currentEp
		final_eps.sort()
		for ep in final_eps:
			if ep > currentEp:
				ep.Get()
				if ep > latestEp:
					latestEp = ep
			#next
		
        # update the latest episode in the config file
		if isinstance(latestEp, SeasonalEpisode):
			cp.set(show, 'season', latestEp.season)
			cp.set(show, 'episode', latestEp.episode)
		elif isinstance(latestEp, DatedEpisode):
			cp.set(show, 'year', latestEp.year)
			cp.set(show, 'month', latestEp.month)
			cp.set(show, 'day', latestEp.day)
				
		#next

	# save updates to the config file
	fp = open(os.path.expanduser(CONFIGFILE), 'w')
	cp.write(fp)
	fp.close()
	
	# DONE
	return 0


if __name__ == "__main__":
	sys.exit(main())			

	
