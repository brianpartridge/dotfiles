#!/usr/bin/env python
# encoding: utf-8
"""
sandbox-opener.py

Created by Brian Partridge.

Pipe output from 'gobuild sandbox queue' into this script to open buildweb urls.
"""

import sys
import webbrowser

def main():
    # Read from stdin
    lines = sys.stdin.readlines()
    
    for line in lines:
        sys.stdout.write(line)
    
    # Open the browser if a success URL was provided
    lastLine = lines[-1]
    index = str.find(lastLine, "http")
    if index > 0:
        url = lastLine[index:]
        webbrowser.open(url)
        print "Opening %s" % url

if __name__ == "__main__":
	sys.exit(main())
