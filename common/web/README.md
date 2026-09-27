# Transmission web UI, served by Apache

The web UI that Transmission 2.93 serves on port 9091, kept in this
repository under `transmission/`, deployed to the Mac's built-in Apache, and
talking to the same Transmission through an RPC proxy. Because the copy lives
here, it can be changed and extended without touching Transmission itself.

    Browser ──▶ Apache :80 ── /transmission/web/*  ──▶ /Library/WebServer/Documents/transmission/web
                           └─ /transmission/rpc    ──▶ proxy ──▶ Transmission :9091

The UI calls the RPC at the relative path `../rpc`, so as long as it is served
from `/transmission/web/`, the only server-side piece is the proxy rule.

`transmission/UPSTREAM` records where the files came from (the `web/` tree at
Transmission's `2.93` tag, verbatim apart from the autotools `Makefile.am`
files). `transmission/LICENSE` is upstream's GPL v2.

## Setup (once)

1. Enable remote access in Transmission (Preferences > Remote) if it is not
   already; that is what listens on port 9091. Leave "Only allow these IP
   addresses" alone. The proxy talks to Transmission as `127.0.0.1`, which
   its hostname whitelist always accepts.

2. Give yourself a place under Apache's document root:

       sudo mkdir -p /Library/WebServer/Documents/transmission
       sudo chown $USER /Library/WebServer/Documents/transmission

3. Install the Apache config and reload. Apache must already be running
   (`sudo apachectl start`, and
   `sudo launchctl load -w /System/Library/LaunchDaemons/org.apache.httpd.plist`
   to survive reboots; the transfers dashboard setup does the same).

       sudo cp ~/dotfiles/common/conf/apache/transmission.conf /etc/apache2/other/
       sudo apachectl configtest
       sudo apachectl graceful

4. Deploy and open `http://<mac-name>.local/transmission/`:

       ~/bin/transmission-web-deploy.sh

## Day to day

Edit files under `common/web/transmission/`, then:

    ~/bin/transmission-web-deploy.sh

The deploy copies the tree into place with an atomic swap, writes a
`DEPLOYED` file naming the commit it came from (and whether the tree had
uncommitted changes), and prints the two HTTP checks below.

## Checking it works

    curl -sI http://localhost/transmission/ | head -1                 # 301 to /transmission/web/
    curl -sI http://localhost/transmission/web/ | head -1             # 200
    curl -si -X POST http://localhost/transmission/rpc | head -1      # 409 from Transmission (session id handshake)

A 409 on the last one is correct: it proves the proxy reached Transmission.
A 503 means Transmission's remote access is off or on another port. A 404 on
the second means nothing has been deployed yet.

## Working on it

A dev server serves this checkout the way Apache does, so edits show up on
reload without deploying. It runs on the system Ruby with no gems:

    ruby ~/dotfiles/common/web/tools/devserver.rb            # http://localhost:8080/transmission/
    ruby ~/dotfiles/common/web/tools/devserver.rb --mock     # no Transmission needed: sample torrents and transfers

Without `--mock` it proxies the RPC to `localhost:9091` (`--rpc URL` to point
elsewhere, for example at the server from a laptop) and serves the transfers
dashboard directory for `transfers.json` (`--transfers DIR`).

## Extending it

Transmission 2.93's UI is plain HTML, CSS and jQuery: `transmission/index.html`,
`transmission/javascript/*.js` (`transmission.js` is the application,
`remote.js` the RPC client, `torrent-row.js` the list rows, `inspector.js` the
details pane) and `transmission/style/transmission/*.css`.

Keep upstream's files untouched where possible. Local additions live in
`transmission/javascript/extras/` and `transmission/style/extras.css`, and
`index.html` includes them after upstream's scripts. They hook the global
`Transmission` and `Torrent` objects rather than editing them, so bringing in
a newer upstream tree later is a matter of re-adding two lines to `index.html`.

### Transfers indicator (`javascript/extras/transfers.js`)

Adds a badge to each finished torrent showing how `torrent-finished.rb`
processed it:

| Badge | Meaning |
|---|---|
| **TV**, **Movie** (green) | filed for Plex; hover for the destination |
| **eBook**, **Comic**, **Audiobook** (blue-grey) | recognised, recorded, not filed anywhere |
| **Other** (grey) | finished fine, nothing to file: not TV or a movie, no media files, or nothing usable in an archive |
| **Failed** (red) | the handler hit an error; hover for the message |
| **Not handled** (red) | completed in the last 7 days but the script left no record, so it never ran or crashed before recording |

Torrents still downloading, and ones that completed before the window, get no
badge. Clicking a badge opens the transfers dashboard. The data is
`/transfers/transfers.json`, which `transfers-dashboard.rb` writes next to the
dashboard page (the latest record per torrent, keyed by hash and by name),
refreshed every minute by the page.

### Extra filters (`javascript/extras/filters.js`)

Two more selects in the filter bar, applied on top of Transmission's own
"Show", tracker and text filters:

- **Handling**: Any, Filed, Filed: TV, Filed: Movie, Other, Other: eBook /
  Comic / Audiobook, Failed, Not handled, No record. Uses the same
  classification as the badges; "Other" includes the named kinds.
- **Age**: Any, Added today / this week / this month, Added over a month ago,
  Finished over a week / a month ago. "Finished" uses Transmission's
  completion time, so unfinished torrents never match those.

Choices are remembered per browser. "Filed" plus "Finished over a month ago"
is the list of things that are safe to remove.

### Dark mode (`javascript/extras/theme.js`, `style/dark.css`)

Follows the system's colour scheme by default. The new footer button (◐)
cycles through follow the system, dark and light, and remembers the choice
per browser. Only colours are overridden: upstream's icons are inverted where
they sit on light buttons, progress bars keep their fills, dialogs and the
preferences window pick up dark jQuery UI colours. macOS 10.13 itself has no
dark mode, so on the Mac's own browser use the toggle; phones and newer
laptops switch automatically.

The same directory can also replace the UI Transmission serves itself on port
9091: Transmission looks in `~/Library/Application Support/Transmission/web`
before its own bundle, so a symlink there makes both addresses show the
customised copy.

    ln -s ~/dotfiles/common/web/transmission ~/Library/Application\ Support/Transmission/web

## Upgrading the upstream copy

If Transmission is ever upgraded, bring in the matching `web/` tree so the UI
and the daemon agree, then re-apply local changes from the diff:

    git clone --depth 1 --branch <tag> https://github.com/transmission/transmission /tmp/tr
    rm -rf ~/dotfiles/common/web/transmission && cp -R /tmp/tr/web ~/dotfiles/common/web/transmission
    find ~/dotfiles/common/web/transmission -name Makefile.am -delete
    # update transmission/UPSTREAM, then `git diff` shows upstream's changes against yours

## Exposure

Anything that can reach the Mac on port 80 can now control Transmission,
without a password, exactly as it could on port 9091. Keep it on the home
network.
