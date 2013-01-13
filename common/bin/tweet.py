#!/usr/bin/python

# This file shows a simple way to trigger a tweet using the 't' cli utility for twitter.  The tweet method can be dropped into any python script to tweet.

import os

def tweet(message):
    t_cli = "/usr/bin/t"

    # TODO: ensure that 't' exists

    maxLength = 140
    msg = message
    if len(msg) > maxLength:
        msg = msg[:maxLength]
    cmd = "%s update \"%s\"" % (t_cli, msg)
    #print("tweet: %s" % cmd)
    os.popen(cmd)

