# Transfers: notifications and dashboard

How a completed Transmission download gets filed for Plex, how you find out
about it, and how to see what happened to recent transfers.

## Pieces

| File | Role |
|---|---|
| `torrent-finished.sh` | What Transmission calls. Fixes `PATH`, captures all output to `~/logs/torrent-finished.out`, runs the Ruby script. |
| `torrent-finished.rb` | Hardlinks the media into the TV or movies folder (each file on its own name for season packs), records the outcome, notifies, refreshes the dashboard. Exit 1 on error. |
| `media-hardlinks.rb` | One-time conversion of the old symlinks in the library into hardlinks. Dry run unless `--apply`. |
| `lib/torrent_handler.rb` | The filing logic, testable on its own. |
| `lib/transfer_log.rb` | Append-only JSONL record of every run: `~/logs/transfers.jsonl`. The dashboard reads this, not the text log. |
| `lib/notify.rb` | Pushover client. Never raises. `lib/tweet.rb` now delegates here, so `tvrss.rb` and `wishlist-downloader.rb` notify too. |
| `lib/transmission_rpc.rb` | Asks Transmission which torrents exist and whether they are complete. |
| `lib/transfer_dashboard.rb`, `transfers-dashboard.rb` | Static HTML dashboard, terminal view, daily digest. |
| `../../home-server/Library/LaunchAgents/*.plist` | Regenerate the dashboard every 30 minutes; send the digest nightly. |

## One-time setup

1. **Pushover.** Create an application at https://pushover.net/apps/build and save
   the credentials where the other scripts keep theirs:

       cat > ~/Dropbox/conf/pushover.json <<EOF
       { "token": "<application API token>", "user": "<your user key>" }
       EOF

   Optional keys: `"device"`, `"sound"`. Test it:

       ruby -r ./lib/notify -e 'p Notify.push("hello", title: "Transfers")'

2. **Transmission done-script.** Preferences > Transfers > Management: tick
   "Call script when download completes" and choose `~/bin/torrent-finished.sh`
   (the wrapper, not the `.rb`). Transmission 4 also offers a
   "when seeding completes" hook; leave that one unset.

3. **Transmission remote access**, so the dashboard can spot torrents that
   finished without the script running. Preferences > Remote > "Enable remote
   access", default port 9091, no authentication needed for localhost. If you
   set a username/password or a different port:

       cat > ~/Dropbox/conf/transmission.json <<EOF
       { "url": "http://localhost:9091/transmission/rpc", "username": "...", "password": "..." }
       EOF

4. **Launch agents.** After `stow home-server` the plists are symlinked into
   `~/Library/LaunchAgents`. Load them once:

       launchctl load ~/Library/LaunchAgents/com.brianpartridge.transfers-dashboard.plist
       launchctl load ~/Library/LaunchAgents/com.brianpartridge.transfers-digest.plist

   If launchd refuses a symlinked plist, copy the files instead of stowing them.

5. **Serve the dashboard with the Mac's built-in Apache.** macOS 10.13 ships
   Apache 2.4; this turns it on, keeps it running across reboots, and gives
   your user a folder under its document root to write into:

       sudo apachectl start
       sudo launchctl load -w /System/Library/LaunchDaemons/org.apache.httpd.plist
       sudo mkdir -p /Library/WebServer/Documents/transfers
       sudo chown $USER /Library/WebServer/Documents/transfers

   The dashboard is written to `/Library/WebServer/Documents/transfers/index.html`
   by default and is reachable from any device on your network at
   `http://<mac-name>.local/transfers/`. The nightly digest carries that link.
   Check the name with `scutil --get LocalHostName`; if the page should be
   reached at some other address, set `TRANSFER_DASHBOARD_URL` in the digest
   launch agent. To write the page somewhere else entirely, set
   `TRANSFER_DASHBOARD` or use `transfers-dashboard.rb --out PATH`.

   Anyone on your network can open the page, and it lists file names and
   paths, so do not expose it to the internet without authentication.

## Ruby

Everything here runs on the macOS system Ruby (2.3), so `./bin/transfers-dashboard.rb`
works from any shell. The exception is talking to Pushover: the system Ruby's
OpenSSL is too old for modern TLS, so notifications need Homebrew's Ruby. The
Transmission wrapper and the launch agents put `/usr/local/bin` first on `PATH`
for that reason. For a manual test, call it explicitly:

    /usr/local/bin/ruby ~/bin/transfers-dashboard.rb --digest

## Why hardlinks

The library entry and the torrent's file are two names for the same data, so
removing the torrent (with or without its data) leaves the item in Plex, and
deleting the item from the library leaves the torrent seeding. No extra disk
space is used. This needs both to be on the same volume; when they are not,
the handler falls back to a symlink and says so in the record and the
notification ("Symlinked ... (different volume)").

Existing symlinks from before this change can be converted in place, without
touching Transmission:

    ~/bin/media-hardlinks.rb            # dry run
    ~/bin/media-hardlinks.rb --apply

Dangling symlinks (target already gone) are reported and left alone.

## Day to day

    transfers-dashboard.rb            # regenerate the HTML
    transfers-dashboard.rb --text     # last 25 transfers in the terminal
    transfers-dashboard.rb --text 100
    transfers-dashboard.rb --digest   # send the 24h summary now

Notifications you will get:

- **TV ready / Movie ready** on every successful transfer, including season
  packs, where every episode is linked on its own file name.
- **eBook / Comic / Audiobook downloaded** when the download is recognised as
  one of those. Nothing is moved; the record, dashboard and web UI badge say
  what it is. Rules: `cbr`/`cbz` means comic; `epub`/`mobi`/`azw` means eBook;
  PDF only is a comic when the name looks like a comic release (`#12`, `v03`,
  `(Digital)`, "comic", "TPB"), otherwise an eBook; an `m4b`, or three or more
  `mp3`/`m4a` files, means audiobook (a music album will be called an
  audiobook too; refine `OtherMedia` in `lib/torrent_handler.rb` if that matters).
  Video always wins when both are present.
- **Transfer complete** when the download finished fine but there was nothing
  to file for Plex and it is none of the above: no media files, a name that is
  neither `S01E02` nor `Title.2004`, or an archive that extracted to nothing
  usable. This is not an error; the dashboard counts it as "other".
- **Transfer failed** (high priority) when something went wrong: destination
  volume not mounted, copy failed, `unrar` missing or failing, a real file in
  the way of a movie symlink, or a crash.
- **Nightly digest** at 21:00 with counts for the day, plus any torrent that
  Transmission says completed in the last 7 days but that has no record. The digest is sent even
  when nothing happened: if it stops arriving, the pipeline itself is broken.

## Where to look when something is off

| Symptom | Look at |
|---|---|
| Notification says failed | The record's Details on the dashboard: error, backtrace, and a `Re-run` command you can paste into a terminal. |
| Dashboard lists "complete but unhandled" (torrents that finished in the last 7 days with no record) | `~/logs/torrent-finished.out`. If there is no entry for that torrent, Transmission never ran the script (check the preference and that the `.sh` is executable). If there is an entry but it stops short, that output is the crash. |
| No notifications at all | `~/logs/torrent-finished.out` will contain `[notify] ...` lines explaining why (missing config, HTTP error). |
| Dashboard 404s or is not reachable | `sudo apachectl status` or `curl -I http://localhost/transfers/` on the Mac; make sure the launch daemon was loaded with `-w` so Apache survives a reboot. |
| Dashboard shows "Transmission unreachable" | Remote access is off, or `transmission.json` is wrong. Everything else still works. |
| Nightly digest missing | `launchctl list | grep transfers` and `~/logs/transfers-digest.out`. |

Logs:

- `~/logs/torrent-finished.out`: everything the wrapper captured, in order, rotated at 5 MB.
- `~/logs/torrent-finished.log`: the Ruby script's own log, 10 files of 10 MB
  (it used to be 10 files of 1 KB, which is why history kept vanishing).
- `~/logs/transfers.jsonl`: one JSON object per run; the dashboard's source of truth.
- `transfers.json` next to the dashboard page: the latest record per torrent, read by the
  Transmission web UI's transfers indicator (see `common/web/README.md`).

## Record format

Each line of `transfers.jsonl`:

    ts, status (ok|other|error), outcome (tv|movie|ebook|comic|audiobook|no_media|multiple_media|unknown_media|error|no_torrent),
    action (link|symlink|extract_link|extract_symlink|none), message, media_file, destination,
    torrent {name, directory, hash, id}, error {class, message, backtrace}, duration_s, notified, repro

## Tests

    cd ~/bin && rake            # or: rspec
