#!/usr/bin/python

# This is an attempt to create a simple system-wide wrapper around the python twitter module so that any script can tweet as the systemc configured user... It doesn't work properly.  Authentication is done and you can list the timelines, but posting updates is broken.

import os
from twitter import *

class TwitterWrapper:
    _twitter = None

    def __init__(self):
        pass

    def auth(self):
        consumer_key_file = os.path.expanduser("~/.bppythontweeter_consumer_key")
        consumer_secret_file = os.path.expanduser("~/.bppythontweeter_consumer_secret")

        # TODO: test that the files exist

        fp = open(consumer_key_file, "r")
        consumer_key = fp.readline().rstrip("\n")
        fp.close()

        fp = open(consumer_secret_file, "r")
        consumer_secret = fp.readline().rstrip("\n")
        fp.close()

        print consumer_key
        print consumer_secret

        oauth_creds_file = os.path.expanduser("~/.bppythontweeter_oauth")
        if not os.path.exists(oauth_creds_file):
            oauth_dance("BPPythonTweeter", consumer_key, consumer_secret, oauth_creds_file)

        oauth_token, oauth_secret = read_token_file(oauth_creds_file)

        self._twitter = Twitter(auth=OAuth(oauth_token, oauth_secret, consumer_key, consumer_secret))
        pass

    def tweet(self, message):
        print self._twitter
        print message
        print self._twitter.statuses
        self._twitter.statuses.update(status=message)
        pass

tw = TwitterWrapper()
tw.auth()
# tl = tw._twitter.statuses.public_timeline()
# print tl
#tw.tweet("this is a tweet fro bppythontweeter")
