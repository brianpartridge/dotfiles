#!/usr/bin/python

from AppKit import *
import sys
 
# Affiliate details.
account = '11l5YI'
campaign = ''
 
# =============================
 
# Get the URL from clipboard
clipboard = NSPasteboard.generalPasteboard()
clip = clipboard.stringForType_(NSStringPboardType).strip()
if clip.find('https://itunes.apple.com/') != 0:
    print('Not an iTunes URL.')
    sys.exit(1)
  
# Add my affiliate token and campaign to the URL.
if '?' in clip:
    url = '%s&at=%s' % (clip, account)
else:
    url = '%s?at=%s' % (clip, account)
 
if len(campaign):
    url = '%s&ct=%s' % (url, campaign)
 
# Write it out
clipboard.clearContents()
clipboard.writeObjects_(NSArray.arrayWithObject_(url))
print('Copied affiliate URL to clipboard.')