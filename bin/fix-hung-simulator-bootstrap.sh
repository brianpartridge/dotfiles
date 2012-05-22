#!/bin/bash

# Source: http://www.mikeash.com/pyblog/solving-simulator-bootstrap-errors.html
launchctl list | grep UIKitApplication | awk '{print $3}' | xargs launchctl remove