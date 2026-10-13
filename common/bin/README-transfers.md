# Transfers: notifications and dashboard

How a completed Transmission download gets filed for Plex, how you find out
about it, and how to see what happened to recent transfers.

## Pieces

| File | Role |
|---|---|
| `torrent-finished.sh` | What Transmission calls. Fixes `PATH`, captures all output to `~/logs/torrent-finished.out`, runs the Ruby script. |
| `torrent-finished.rb` | Hardlinks the media into the TV or movies folder (each file on its own name for season packs), records the outcome, notifies, refreshes the dashboard. With `--file-other`, also copies eBooks, comics, audiobooks and music into `~/Dropbox/media`. Exit 1 on error. |
| `media-hardlinks.rb` | One-time conversion of the old symlinks in the library into hardlinks. Dry run unless `--apply`. |
| `lib/torrent_handler.rb` | The filing logic, testable on its own. |
| `lib/transfer_log.rb` | Append-only JSONL record of every run: `~/logs/transfers.jsonl`. The dashboard reads this, not the text log. |
| `lib/notify.rb` | Pushover client. Never raises. `lib/tweet.rb` now delegates here, so `tvrss.rb` and `wishlist-downloader.rb` notify too. |
| `lib/transmission_rpc.rb` | Asks Transmission which torrents exist and whether they are complete. |
| `lib/transfer_dashboard.rb`, `transfers-dashboard.rb` | Static HTML dashboard and terminal view. |
| `lib/media_config.rb` | Where everything lives: library, Dropbox media folders, the NAS, the job queue. |
| `lib/promoter.rb`, `lib/job_queue.rb`, `lib/transfers_worker.rb`, `transfers-worker.rb` | Promoting items to the NAS, triggered from the dashboard and run in the background (see below). |
| `../web/cgi/transfers-api.rb` | The dashboard's one write endpoint, run by Apache: it only drops a request file into the queue. |
| `../../home-server/Library/LaunchAgents/*.plist` | Regenerate the dashboard every 30 minutes; run the worker whenever the queue is non-empty. |

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

4. **Launch agent.** After `stow home-server` the plist is symlinked into
   `~/Library/LaunchAgents`. Load it once:

       launchctl load ~/Library/LaunchAgents/com.brianpartridge.transfers-dashboard.plist

   If launchd refuses a symlinked plist, copy the file instead of stowing it.

5. **Serve the dashboard with the Mac's built-in Apache.** macOS 10.13 ships
   Apache 2.4; this turns it on, keeps it running across reboots, and gives
   your user a folder under its document root to write into:

       sudo apachectl start
       sudo launchctl load -w /System/Library/LaunchDaemons/org.apache.httpd.plist
       sudo mkdir -p /Library/WebServer/Documents/transfers
       sudo chown $USER /Library/WebServer/Documents/transfers

   The dashboard is written to `/Library/WebServer/Documents/transfers/index.html`
   by default and is reachable from any device on your network at
   `http://<mac-name>.local/transfers/`. Notifications link to that address.
   Check the name with `scutil --get LocalHostName`; if the page should be
   reached at some other address, set `TRANSFER_DASHBOARD_URL` in
   `torrent-finished.sh`. To write the page somewhere else entirely, set
   `TRANSFER_DASHBOARD` or use `transfers-dashboard.rb --out PATH`.

   Anyone on your network can open the page, and it lists file names and
   paths, so do not expose it to the internet without authentication.

6. **Promote-to-NAS buttons** (optional, see "Promoting to the NAS" below).
   The dashboard posts to a CGI script that Apache runs as `_www`; it writes
   one small file into a queue folder, and launchd runs the worker as you.

       mkdir -p ~/logs/transfers-queue && chmod 1777 ~/logs/transfers-queue
       sudo chown $USER /Library/WebServer/CGI-Executables   # so the deploy script can update the CGI
       transmission-web-deploy.sh                              # copies ../web/cgi/transfers-api.rb there
       sudo cp ~/dotfiles/common/conf/apache/transmission.conf /etc/apache2/other/ && sudo apachectl graceful
       launchctl load ~/Library/LaunchAgents/com.brianpartridge.transfers-worker.plist

   Check: `curl -si -X POST http://localhost/transfers/api` should answer
   `403` with a JSON error (it refuses anything without the dashboard's
   header); a `404` means the Apache config is not loaded, `500` means
   `/usr/bin/ruby` could not write to the queue folder (the body says so).

## Ruby

Everything here runs on the macOS system Ruby (2.3), so `./bin/transfers-dashboard.rb`
works from any shell. The exception is talking to Pushover: the system Ruby's
OpenSSL is too old for modern TLS, so notifications need Homebrew's Ruby. The
Transmission wrapper and the launch agent put `/usr/local/bin` first on `PATH`
for that reason. For a manual test, call it explicitly:

    cd ~/bin && /usr/local/bin/ruby -r ./lib/notify -e 'p Notify.push("hello", title: "Transfers")'

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

Notifications you will get:

- **TV ready / Movie ready** on every successful transfer, including season
  packs, where every episode is linked on its own file name.
- **eBook / Comic / Audiobook / Music downloaded** when the download is
  recognised as one of those. Nothing is moved; the record, dashboard and web
  UI badge say what it is. Rules: `cbr`/`cbz` means comic; `epub`/`mobi`/`azw`
  means eBook; PDF only is a comic when the name looks like a comic release
  (`#12`, `v03`, `(Digital)`, "comic", "TPB"), otherwise an eBook; an `m4b`
  means audiobook. Other audio (`mp3`, `m4a`, `flac`, ...) is an audiobook or
  music, decided by evidence in this order: the name says audiobook
  ("Unabridged", "Narrated", "64kbps"); lossless formats or a `cue`/`log`
  sidecar mean music; the name says music ("FLAC", "320", "Album", "Vinyl",
  "OST", "Remastered"); most files are named like chapters ("Chapter 03",
  "Part 2") means audiobook; otherwise three or more files is an audiobook
  and fewer is music. Video always wins. Tune `OtherMedia` in
  `lib/torrent_handler.rb` if a rule misfires.
  These are not filed automatically. The dashboard (and the log) carry the
  exact command that copies the download, as it is (a single file or the
  whole directory), into `~/Dropbox/media/comics`, `ebooks`, `audiobooks` or
  `music`; the notification just links to the dashboard:

      /usr/bin/env TR_TORRENT_DIR='...' TR_TORRENT_NAME='...' ruby ~/bin/torrent-finished.rb --file-other

  The dashboard has a Copy button next to it (and next to every re-run
  command), and in the Transmission web UI clicking the item's badge copies
  it. Paste it into a terminal on the Mac when you want the item. It is safe
  to re-run: an item
  already present is left alone, and the copy lands under a temporary name
  and is renamed when complete so Dropbox never syncs a partial item. To file
  these automatically, add `--file-other` to the command in
  `torrent-finished.sh`. Override the root with `$DROPBOX_MEDIA`.
- **eBook / Comic / Audiobook / Music filed** when run with `--file-other` and
  the copy succeeded.
- **Transfer complete** when the download finished fine but there was nothing
  to file for Plex and it is none of the above: no media files, a name that is
  neither `S01E02` nor `Title.2004`, or an archive that extracted to nothing
  usable. This is not an error; the dashboard counts it as "other".
- **Transfer failed** (high priority) when something went wrong: destination
  volume not mounted, copy failed, `unrar` missing or failing, a real file in
  the way of a movie symlink, or a crash.
- **Promoted to NAS** / **Promote failed** (high priority) for jobs started
  from the dashboard, below.

## Promoting to the NAS

The local library (`~/Media/tv`, `~/Media/movies`) is hardlinks into the
downloads folder. Promoting an item copies it to the NAS at `/Volumes/Media`
under the same relative path (`~/Media/tv/X.mkv` becomes
`/Volumes/Media/tv/X.mkv`) and then removes the local library name. Because
that name was a hardlink, the download keeps its copy and goes on seeding;
nothing in the downloads folder is ever touched. A symlink is removed the
same way. A plain file with no other link is a true move.

On the dashboard, every transfer that was linked into the library and has
not been promoted since has a **Promote to NAS** button. Clicking it queues
a job; the page says so and reloads a few seconds later. The job runs in the
background and appears under **Jobs** with its state and log; the log of a
failed job is expanded. Each promotion is also a record in the transfer log
(action `promote`), so the row and the web UI badge show the new state, and
you get a notification either way.

The same thing from a terminal:

    transfers-worker.rb promote <torrent hash>              # everything that transfer filed
    transfers-worker.rb promote ~/Media/tv/X.mkv            # one file
    transfers-worker.rb promote ~/Media/tv/X.mkv --keep-link   # leave a symlink to the NAS behind
    transfers-worker.rb enqueue promote <hash>              # queue it for launchd instead
    transfers-worker.rb                                     # run whatever is queued

Rules the worker follows: it refuses to run unless something is mounted
exactly at `/Volumes/Media` (an empty mount point is not written into); it
copies to a temporary name on the NAS and renames it only once the size
matches, so a half-copied file is never mistaken for a finished one; an item
already on the NAS with the same size is not copied again; the local name is
removed only after the copy is verified. Season packs are promoted episode
by episode, found by identity with the torrent's files, so a file of the same
name that belongs to some other torrent is left alone. Override the NAS path
with `$NAS_MEDIA`, and the queue and job folders with `$TRANSFERS_QUEUE` and
`$TRANSFERS_JOBS` (defaults under `~/logs`).

How the pieces fit: the dashboard button `POST`s to `/transfers/api` with the
header `X-Requested-With: transfers`, which a browser never adds on its own,
so another site cannot trigger it. Apache runs `transfers-api.rb` as `_www`
with the system Ruby; the script validates the request (a known action and a
40-hex hash) and writes it into `~/logs/transfers-queue`, which is why that
folder is world-writable and sticky. launchd watches the folder
(`QueueDirectories`) and starts `transfers-worker.rb` as you whenever it is
non-empty. The worker moves each request into its own folder under
`~/logs/transfers-jobs/<time>-promote-<name>/` (`request.json`, `status.json`,
`log.txt`), does the work, appends a record, notifies, and regenerates the
dashboard. Old job folders can be deleted at any time.

## Where to look when something is off

| Symptom | Look at |
|---|---|
| Notification says failed | The record's Details on the dashboard: error, backtrace, and a `Re-run` command you can paste into a terminal. |
| Dashboard lists "complete but unhandled" (torrents that finished in the last 7 days with no record) | `~/logs/torrent-finished.out`. If there is no entry for that torrent, Transmission never ran the script (check the preference and that the `.sh` is executable). If there is an entry but it stops short, that output is the crash. |
| No notifications at all | `~/logs/torrent-finished.out` will contain `[notify] ...` lines explaining why (missing config, HTTP error). |
| Dashboard 404s or is not reachable | `sudo apachectl status` or `curl -I http://localhost/transfers/` on the Mac; make sure the launch daemon was loaded with `-w` so Apache survives a reboot. |
| Free-space tile missing | It needs Transmission's remote access (the download folder comes from `session-get`); the figures come from `df` on that folder, or from Transmission's own number when `df` cannot run. |
| Dashboard shows "Transmission unreachable" | Remote access is off, or `transmission.json` is wrong. Everything else still works. |
| Promote button says "Could not queue" | The message is the CGI's: `403` means the header did not arrive (a proxy stripped it?), `404` means `transmission.conf` is not loaded in Apache, `500` means `~/logs/transfers-queue` is missing or not `chmod 1777`. |
| Promote queued but nothing happens | The worker's launch agent is not loaded, or `~/logs/transfers-worker.out` has the crash. Run `transfers-worker.rb` by hand to see it. A request that was not valid JSON is parked in `~/logs/transfers-queue/rejected/`. |
| Job failed with "NAS is not mounted" | Mount `/Volumes/Media` in the Finder, then click Promote again (or `transfers-worker.rb promote <hash>`). Nothing was changed locally. |

Logs:

- `~/logs/torrent-finished.out`: everything the wrapper captured, in order, rotated at 5 MB.
- `~/logs/torrent-finished.log`: the Ruby script's own log, 10 files of 10 MB
  (it used to be 10 files of 1 KB, which is why history kept vanishing).
- `~/logs/transfers.jsonl`: one JSON object per run; the dashboard's source of truth.
- `~/logs/transfers-worker.out` and `~/logs/transfers-jobs/*/log.txt`: the dashboard-triggered jobs.
- `transfers.json` next to the dashboard page: the latest record per torrent, read by the
  Transmission web UI's transfers indicator (see `common/web/README.md`).

## Record format

Each line of `transfers.jsonl`:

    ts, status (ok|other|error), outcome (tv|movie|ebook|comic|audiobook|music|no_media|multiple_media|unknown_media|error|no_torrent),
    action (link|symlink|extract_link|extract_symlink|copy|promote|none), message, media_file, destination,
    torrent {name, directory, hash, id}, error {class, message, backtrace}, duration_s, notified, repro,
    file_command (the --file-other command for a recognised-but-unfiled download),
    destinations and job (promotions: every file copied to the NAS, and the job folder's name)

## Tests

    cd ~/bin && rake            # or: rspec
