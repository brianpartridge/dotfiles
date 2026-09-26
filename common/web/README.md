# Transmission web UI, served by Apache

A copy of the web UI that Transmission.app serves on port 9091, hosted by the
Mac's built-in Apache instead, and talking to the same Transmission through an
RPC proxy. Because the copy lives in this repository, it can be changed and
extended here without touching Transmission itself.

    Browser ──▶ Apache :80 ── /transmission/web/*  ──▶ files in common/web/transmission
                           └─ /transmission/rpc    ──▶ proxy ──▶ Transmission :9091

The UI calls the RPC at the relative path `../rpc`, so as long as it is served
from `/transmission/web/`, the only server-side piece is the proxy rule.

## Setup (once)

1. Enable remote access in Transmission (Preferences > Remote) if it is not
   already; that is what listens on port 9091. Leave "Only allow these IP
   addresses" alone. The proxy talks to Transmission as `127.0.0.1`, which
   its hostname whitelist always accepts.

2. Import the UI out of the app bundle into this repo, then commit it:

       ~/bin/transmission-web-import.sh            # /Applications/Transmission.app
       git -C ~/dotfiles add common/web/transmission
       git -C ~/dotfiles commit -m "Import Transmission web UI"

   The import records the version in `common/web/transmission/UPSTREAM`.

3. Install the Apache config and reload:

       sudo cp ~/dotfiles/common/conf/apache/transmission.conf /etc/apache2/other/
       sudo apachectl configtest
       sudo apachectl graceful

   Apache must already be running (`sudo apachectl start`, and
   `sudo launchctl load -w /System/Library/LaunchDaemons/org.apache.httpd.plist`
   to survive reboots; the transfers dashboard setup does the same).

4. Open `http://<mac-name>.local/transmission/` from any device on the network.

## Checking it works

    curl -sI http://localhost/transmission/ | head -1                 # 301 to /transmission/web/
    curl -sI http://localhost/transmission/web/ | head -1             # 200
    curl -si -X POST http://localhost/transmission/rpc | head -1      # 409 from Transmission (session id handshake)

A 409 on the last one is correct: it proves the proxy reached Transmission.
A 503 means Transmission's remote access is off or on another port. A 403 on
the second means Apache's `_www` user cannot read the checkout; check
`ls -ld ~ ~/dotfiles ~/dotfiles/common/web`.

## Extending it

Edit the files under `common/web/transmission/` and reload the page; Apache
serves them directly from the checkout. Transmission 3.x ships plain HTML,
CSS and jQuery, so changes are straightforward. Transmission 4.x ships a built
bundle (`transmission-app.js`); it still hosts fine, but meaningful changes
mean building from the `web/` sources in Transmission's repository and
importing the output.

To upgrade after a new Transmission release, run the import again. It refuses
to run over uncommitted changes, and afterwards `git diff` shows upstream's
changes against any customisations, to be merged or reverted as needed.

The same directory can also replace the UI Transmission serves itself on port
9091: Transmission looks in `~/Library/Application Support/Transmission/web`
before its own bundle, so a symlink there makes both addresses show the
customised copy.

    ln -s ~/dotfiles/common/web/transmission ~/Library/Application\ Support/Transmission/web

## Exposure

Anything that can reach the Mac on port 80 can now control Transmission,
without a password, exactly as it could on port 9091. Keep it on the home
network.
