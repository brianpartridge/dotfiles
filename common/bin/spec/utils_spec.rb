require 'rspec'
require 'utils'

describe 'Logging' do 
 it 'writes to STDOUT' do
   expect { success('foo') }.to output("💚  foo\n").to_stdout
   expect { info('foo') }.to output("💛  foo\n").to_stdout
 end

 it 'fatal kills the process' do
   expect { $stderr = StringIO.new; fatal('foo'); $stderr = STDERR }.to raise_error(SystemExit)
   expect { fatal('foo') }.to output("💔  foo\n").to_stderr
 end

end

