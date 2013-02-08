#!/usr/bin/env python
# encoding: utf-8
"""
watchlist-to-wishlist.py

Created by Brian Partridge.
Copyright (c) 2013 Brian Partridge. All rights reserved.
"""

import os
import sys
import feedparser
import logging
import logging.handlers
import time
import subprocess
import json
from optparse import OptionParser

# Import the t cli wrapper
import tweet

# Config

WATCHLIST_FEED_URL = "http://rss.imdb.com/user/ur13693513/watchlist"
WATCHLIST_CONFIGFILE = "~/Dropbox/conf/watchlist.conf" # This file just contains the publish date of top most feed entry.
WISHLIST_URL = "http://hdbits.org/json/wishlistAdd"
WISHLIST_COOKIEFILE = "~/Dropbox/conf/wishlist.conf" # This file just contain the cookie values necessary to communicate with the wishlist site.
LOGFILE = "~/logs/watchlist.log"
LOGLEVEL = logging.DEBUG

# DO NOT MODIFY BELOW THIS LINE #

logger = logging.getLogger("watchlist logger")

def loadLatestEntryDate():
    dateString = None
    path = os.path.expanduser(WATCHLIST_CONFIGFILE)
    if (os.path.exists(path)):
        fp = open(path, 'r')
        dateString = fp.read()
        fp.close()
        
    if dateString == None:
        logger.debug("Loaded: epoch")
        return time.localtime(0)
        
    logger.debug("Loaded: %s" % dateString)
    date = time.strptime(dateString, "%a, %d %b %Y %H:%M:%S")
    return date

def persistLatestEntryDate(date):
    dateString = time.strftime("%a, %d %b %Y %H:%M:%S", date)
    logger.debug("Persisting: %s" % dateString)
    
    path = os.path.expanduser(WATCHLIST_CONFIGFILE)
    fp = open(path, 'w')
    fp.write(dateString)
    fp.close()
    
def loadWishlistCookie():
    cookieString = None
    path = os.path.expanduser(WISHLIST_COOKIEFILE)
    if (os.path.exists(path)):
        fp = open(path, 'r')
        cookieString = fp.read()
        fp.close()
    return cookieString
    
def processWatchlist():
    entriesToAdd = []
    newestEntryDate = lastKnownEntryDate = loadLatestEntryDate()
    
    ff = feedparser.parse(WATCHLIST_FEED_URL)
    logger.info("Processing %d entries" % len(ff['entries']))
    for entry in ff['entries']:
        date = entry['published_parsed']
        if (time.mktime(date) - time.mktime(lastKnownEntryDate)) > 0:
            entriesToAdd.append(entry)
            if (time.mktime(date) - time.mktime(newestEntryDate)) > 0:
                newestEntryDate = date

    for entry in entriesToAdd:
        name = entry['title']
        link = entry['link']
        logger.info("Adding %s - %s" % (name, link))
        addToWishlist(name, link)
        
        # Don't hammer the wishlist, wait a few secs
        time.sleep(5)
    
    persistLatestEntryDate(newestEntryDate)
    
def addToWishlist(title, imdbURL):
    cookie = '"%s"' % loadWishlistCookie()
    imdb = "imdb=%s" % imdbURL
    args = ["curl", "--silent", "-X", "POST", "-d", imdb, "-b", cookie, WISHLIST_URL]
    logger.debug("CURL cmd: %s" % str(args))
    output = subprocess.check_output(args)
    logger.debug("CURL output: %s" % output)
    result = json.loads(output)
    status = result['status']
    if status == 1:
        logger.info("Added %s to wishlist" % title)
        tweet.tweet("SUCCESS:Watchlist - %s - %s" % (title, imdbURL))
    else:
        message = result['message']
        logger.error("Unable to add %s to wishlist: %s" % (title, message))
        tweet.tweet("FAILURE:Watchlist - %s - %s - %s" % (title, imdbURL, message))

def main2(options, args):
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
    
    # Logic
    processWatchlist()
    

def main():
    parser = OptionParser(version="%prog 1.0")
    parser.add_option("-v", "--verbose",
                      action="store_true", 
                      dest="verbose", 
                      default=False,
                      help="display additional information")

    (options, args) = parser.parse_args()
    main2(options, args)

if __name__ == "__main__":
	sys.exit(main())
