# frozen_string_literal: true

require 'tmpdir'
require 'logger'

# Shared helpers for the transfer pipeline specs.
module TransferSpecHelpers
  def with_tmpdir
    Dir.mktmpdir('transfers') { |dir| yield dir }
  end

  def touch(path, content = 'x')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def null_logger
    Logger.new(File::NULL)
  end

end

# Stands in for a Net::HTTPResponse.
FakeResponse = Struct.new(:code, :body, :headers) do
  def [](key)
    (headers || {})[key]
  end
end

RSpec.configure { |c| c.include TransferSpecHelpers }
