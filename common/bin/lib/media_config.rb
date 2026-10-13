# frozen_string_literal: true

# Where things live on the home server. One place for every script.
# Nothing here uses ~ expansion, so it also loads under Apache's _www user.
module MediaConfig
  HOME = '/Users/theater'

  # Local Plex library (hardlinks into the downloads).
  MEDIA_ROOT = '/Users/theater/Media'
  TV_DIRECTORY = File.join(MEDIA_ROOT, 'tv')
  MOVIE_DIRECTORY = File.join(MEDIA_ROOT, 'movies')

  # eBooks, comics, audiobooks and music, copied only with --file-other.
  DROPBOX_MEDIA = ENV['DROPBOX_MEDIA'] || File.join(HOME, 'Dropbox', 'media')
  OTHER_DIRECTORIES = {
    'comic' => File.join(DROPBOX_MEDIA, 'comics'),
    'ebook' => File.join(DROPBOX_MEDIA, 'ebooks'),
    'audiobook' => File.join(DROPBOX_MEDIA, 'audiobooks'),
    'music' => File.join(DROPBOX_MEDIA, 'music')
  }.freeze

  # The NAS the local library is promoted to. Items keep their path relative
  # to MEDIA_ROOT, so ~/Media/tv/X.mkv becomes /Volumes/Media/tv/X.mkv.
  NAS_ROOT = ENV['NAS_MEDIA'] || '/Volumes/Media'

  # Dashboard-triggered work: the CGI drops a request file into the queue
  # (world-writable, sticky), launchd runs the worker, each job gets a folder.
  QUEUE_DIR = ENV['TRANSFERS_QUEUE'] || File.join(HOME, 'logs', 'transfers-queue')
  JOBS_DIR = ENV['TRANSFERS_JOBS'] || File.join(HOME, 'logs', 'transfers-jobs')
end
