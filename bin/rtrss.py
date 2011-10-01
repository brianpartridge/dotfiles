#!/usr/bin/env python

"""
rtrss.py
Version 0.3

Copyright (c) 2011 Brian Partridge

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

config_file = "/Users/brian/.rtrss.conf"
torrent_directory = "/Users/brian/rsstorrents"

parsed_feeds = {}

class RtRssFault(Exception):
	def __init__(self, msg):
		self.msg = msg

class Episode():
	def __init__(self, url, name, season, episode):
		self.url = url
		self.name = name
		self.season = season
		self.episode = episode
		
	def Get(self):
		msg = "Getting: %s S%dE%d" % (self.name, self.season, self.episode)
		print msg
		log(msg)

		filename = os.path.join(torrent_directory, "%s S%dE%d rtRSS.torrent" % (self.name, self.season, self.episode))
		try:
			urllib.urlretrieve(self.url, filename)
			# Set metadata that could be useful later
			meta = {1:'type=tv', 2:'name=%s' % self.name, 3:'season=%s' % str(self.season), 4:'episode=%s' % str(self.episode)}
			if self.name == "ufc.main.events":
				meta = {}
			for m in meta:
				print m
		except IOError, e:
			print e
		else:
			print "started %s" % (filename)
			
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

class TvFeed():
	def __init__(self, args):
		self.url = args['url']
		self.keywords = args['keywords']
		self.name = args['name']
		self.label = args['label']
		self.last_season = args['season']
		self.last_episode = args['episode']
		
	def ListEpisodes(self):
		print "Processing", self.label
		
		previously_cached = True
		# cache the parsed feed
		if not parsed_feeds.has_key(self.url):
			previously_cached = False
			print "parsing: ", self.url
			parsed_feeds[self.url] = feedparser.parse(self.url)
		feed = parsed_feeds[self.url]
		if feed.entries:
			print "%d entries" % (len(feed.entries))
		
		eps = []
		for e in feed.entries:
			if not e.link:
				continue

			# print the feed entries if this is the first time with the feed
			if not previously_cached:
				 print "  " + e.title.encode("utf-8")

			# check for keywords
			found = True
			for k in self.keywords:
				if k.lower() not in e.title.lower():
					found = False
					break
			if not found:
				# if any keywords weren't found, move on to the next entry
				continue
			print e.title

			# Remove H.264 as it breaks my regular expression
			if "H.264" in e.title:
				e.title = e.title.replace("H.264", "")
				print e.title
			elif "h.264" in e.title:
				e.title = e.title.replace("h.264", "")
				print e.title
					
			if "tvrss.net" in self.url:
				# parse entry body
				metadata = {}
				tmp1 = e.summary.split(';')
				for tmp2 in tmp1:
					try:
						k,v = tmp2.split(':')
					except ValueError, err:
						print 'value error ',err
						continue
					metadata[k.strip()] = v.strip()
				try:
					#ep = Episode(e.link, metadata['Show Name'].strip(), int(metadata['Season']), int(metadata['Episode']))
					ep = Episode(e.link, self.name.strip(), int(metadata['Season']), int(metadata['Episode']))
				except KeyError, err:
					# some data wasnt provided
					print 'KeyError: ',err
					continue
			elif "UFC" in self.keywords:
				# specific for UFC episodes which don't have a season
				# get info from entry title
				result = re.match(r'UFC (\d+)', e.title)
				if result:
					if "countdown" in e.title.lower():
						print("Skipping the countdown episode");
						continue
					ep = Episode(e.link, self.name, 0, int(result.groups()[0]))
				else:
					# error nothing to compare against
					print("No data found.")
					continue
			elif "Part" in self.keywords:
				# specific for series that use 'Parts' rather then episodes and don't have a season
				# get info from entry title
				result = re.match(r'.+[\._ \-]+Part (\d+)', e.title)
				if result:
					ep = Episode(e.link, self.name, 0, int(result.groups()[0]))
				else:
					# error nothing to compare against
					print("No data found.")
					continue
			else:
				# get info from entry title
				result = re.match(r'(.+)[\._ \-][Ss]?(\d+)?[\._ \-]?[EeXx]?(\d{2})[\._ \-]', e.title)
				if result:
					# if no season # was found default to 1
					# necessary for miniseries
					if result.groups()[1]:
						s_num = int(result.groups()[1])
					else:
						s_num = 1

					e_num = int(result.groups()[2])

					#ep = Episode(e.link, result.groups()[0], s_num, e_num)
					ep = Episode(e.link, self.name, s_num, e_num)
				else:
					# error nothing to compare against
					print("No data found.")
					continue
			eps.append(ep)
			
			# next
		
		return eps

def log(msg):
	fp = open('/Users/brian/logs/rtrss.log', 'a')
	fp.write(str(msg) + "\n")
	fp.close()

def main(argv=None):			
	cp = ConfigParser.ConfigParser()
	cp.read(config_file)

	log(time.strftime('%b %d %Y %H:%M:%S', time.localtime()))
	
	for show in cp.sections():
		# initialize mandatory inputs
		args = {'label': show, 'url': None, 'season': 0, 'episode': 0, 'name':None, 'keywords': []}
		
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
		feed = TvFeed(args)
	
		# retrieve all episodes in the feed
		eps = feed.ListEpisodes()

		# remove duplicates
		final_eps = []
		for ep in eps:
			if ep not in final_eps:
				final_eps.append(ep)
			
		# iterate over the eps and load new eps
		final_eps.sort()
		new_season = int(args['season'])
		new_episode = int(args['episode'])
		for ep in final_eps:
			if ep.season > int(args['season']):
				new_season = ep.season
				new_episode = ep.episode
			elif ep.season == int(args['season']):
				if ep.episode > int(args['episode']):
					new_episode = ep.episode
				else:
					continue
			else:
				continue
					
			if args['season'] != 0 and args['episode'] != 0:
				ep.Get()

			#next
		
		cp.set(show, 'season', new_season)
		cp.set(show, 'episode', new_episode)
				
		#next

	# save updates to the config file
	fp = open(config_file, 'w')
	cp.write(fp)
	fp.close()
	
	# DONE
	return 0


if __name__ == "__main__":
	sys.exit(main())			

	
