#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

SANDBOXDIR=`mktemp -d -t letsencrypt`
CERTDIR="/etc/letsencrypt/live/www.multipleentendre.com"
RENEWOPTS="" #"--dry-run"

function configure_sandbox {
    chmod 777 "$SANDBOXDIR"
}

function renew {
    sudo certbot renew $RENEWOPTS
}

function copy_certs {
    sudo cp -r "$CERTDIR" "$SANDBOXDIR"
}

function open_certs {
    open "$SANDBOXDIR/www.multipleentendre.com"
}

function clear_sandbox {
    sudo rm -r "$SANDBOXDIR"
}

function open_server {
    open "/Applications/Server.app"
}

function display_instructions {
    echo "The SSL certification for www.multipleentendre.com has been renewed and copied to $SANDBOXDIR"
    echo " * Import the certificates into macOS Server."
    echo " * Update the SSL configuration for the website to use the new certificate."
}

function begin_automated_steps {
    echo "Renewing certificates..."
    configure_sandbox
    renew
    copy_certs
}

function begin_manual_steps {
    echo "Opening tools for manual tasks..."
    open_certs
    open_server
    display_instructions
}

function cleanup {
    echo "Cleaning up..."
    clear_sandbox
}

function complete {
    echo "Done"
}

function wait_for_completion {
    read -n1 -r -p "Press any key to continue..." key
    echo ""
}

function run {
    begin_automated_steps
    begin_manual_steps
    wait_for_completion
    cleanup
    complete
}

run

