#!/usr/bin/env python
# encoding: utf-8
"""
pr.py

Created by Brian Partridge.
"""

import sys
from optparse import OptionParser
import subprocess
import webbrowser

def main2(options, args):
    guess = True
    cmd = "/build/trees/bin/post-review" 
    guessOptions = "--guess-description --guess-summary"
    
    # Check tweak command based on user input
    if options.review_id:
        cmd += " -r %d" %options.review_id
        # Since a review is being updated, don't use guess values
        # otherwise previously editted values could be overridden
        guess = False

    if guess:
        cmd += " %s" %guessOptions

    print "Executing command: %s" % cmd
    
    # Execute the command
    cmd_parts = cmd.split(" ")
    p = subprocess.Popen(cmd_parts, stdout=subprocess.PIPE)
    
    # Retrieve and print output
    out, err = p.communicate()
    print out

    # Open the browser if a success URL was provided
    for line in out.split('\n'):
        if line.startswith("http"):
            webbrowser.open(line)

def main():
    parser = OptionParser(version="%prog 1.0")
    parser.add_option("-r", "--review", 
                      dest="review_id",
                      help="update an existing review",
                      action="store",
                      type="int")

    (options, args) = parser.parse_args()
    main2(options, args)

if __name__ == "__main__":
	sys.exit(main())
