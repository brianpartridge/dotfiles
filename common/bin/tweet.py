#!/usr/bin/python

# This file shows a simple way to trigger a tweet using the 't' cli utility for twitter.  The tweet method can be dropped into any python script to tweet.

import os

def tweet(message):
    if len(os.popen("which t").read()) == 0:
        return

    maxLength = 140
    msg = message
    if len(msg) > maxLength:
        msg = msg[:maxLength]
    cmd = "t update \"%s\"" % msg
    os.popen(cmd)

