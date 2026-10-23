# frozen_string_literal: true

require 'rspec'
require 'utils'

describe 'Logging' do
  it 'writes to STDOUT' do
    expect { success('foo') }.to output("🔷  foo\n").to_stdout
    expect { success2('foo') }.to output("  🔹  foo\n").to_stdout
    expect { error('foo') }.to output("♦️  foo\n").to_stdout
    expect { info('foo') }.to output("🔶  foo\n").to_stdout
    expect { info2('foo') }.to output("  🔸  foo\n").to_stdout
  end

  it 'fatal kills the process' do
    expect { $stderr = StringIO.new; fatal('foo'); $stderr = STDERR }.to raise_error(SystemExit)
    expect { expect { fatal('foo') }.to raise_error(SystemExit) }.to output("💔  foo\n").to_stderr
  end
end
