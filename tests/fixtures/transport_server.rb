# Test fixture: real file transport, deliberately no SketchUp geometry API.
require_relative '../../extension/codex_sketchup_bridge/transport'

class EchoAdapter
  def state
    { 'model_token' => 'portable-model', 'revision' => @revision || 0 }
  end

  def capabilities; ['echo']; end

  def validate_target!(request)
    unless request['model_token'] == state['model_token'] && request['expected_revision'] == state['revision']
      CodexSketchupBridge::Protocol.fail!('stale_revision', 'Invalid test target')
    end
  end

  def execute(request, _transport)
    @revision = state['revision'] + 1
    { 'echo' => request['arguments'], 'executions' => @revision }
  end
end

root = ARGV.fetch(0)
transport = CodexSketchupBridge::Transport.new(root, EchoAdapter.new).start
begin
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  until File.exist?(File.join(root, 'test-stop'))
    raise 'Test server timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    transport.tick
    sleep 0.01
  end
ensure
  transport.stop
end
