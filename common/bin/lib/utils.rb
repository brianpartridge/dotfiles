require 'json'

$conf_dir = '~/Dropbox/conf/'

# Config File Management
# Config files live in Dropbox for sync/backup. These commands help access and edit those files.
def conf_file(filename)
    File.expand_path($conf_dir + filename)
end

def first_line_from_file(path)
    File.readlines(File.expand_path(path)).first
end

def load_json_config(filename)
  JSON.parse(open(conf_file(filename)).read)
end

def save_json_config(filename, hash)
  open(conf_file(filename), 'wb') do |f|
    f << JSON.pretty_generate(hash)
  end
end

# File Downloading

def download(url, name, outdir)
    path = File.expand_path(outdir + name)
    info "Downloading #{name} to #{path} from #{url}"
    open(path, 'wb') do |f|
        f << opene(url).read
        success "Downloaded #{name} to #{path}"
    end
end

# Logging

def info(message)
  puts '💛  ' + message
  0
end

def success(message)
  puts '💚  ' + message
  0
end

def fatal(message)
  abort '💔  ' + message
end

