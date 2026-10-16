require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../extension/codex_sketchup_bridge/transport'

class FakeAdapter
  attr_reader :calls
  def initialize; @calls = 0; end
  def state; { 'model_token' => 'model', 'revision' => @calls }; end
  def capabilities; ['create_box']; end
  def validate_target!(r)
    CodexSketchupBridge::Protocol.fail!('model_mismatch', 'Wrong model') unless r['model_token'] == 'model'
  end
  def execute(r, _)
    @calls += 1
    raise 'Deliberate error' if r['arguments']['fail']
    { 'calls' => @calls }
  end
end

class TransportTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir('bridge-'))
    @adapter = FakeAdapter.new
    @transport = CodexSketchupBridge::Transport.new(@dir, @adapter).start
  end
  def teardown
    @transport.stop
    FileUtils.remove_entry(@dir)
  end
  def request(id = 'test', args = {})
    { 'request_id' => id, 'protocol_version' => 1, 'session_id' => @transport.session_id,
      'model_token' => 'model', 'expected_revision' => 0, 'action' => 'create_box',
      'arguments' => args, 'submitted_at' => CodexSketchupBridge::Protocol.timestamp }
  end
  def send_request(data, receipt = 'receipt')
    @transport.atomic_write("inbox/#{receipt}.json", data)
    @transport.tick
  end
  def test_deduplication_and_conflict
    r = request
    send_request(r)
    send_request(r, 'duplicate')
    assert_equal 1, @adapter.calls
    send_request(request('test', { 'different' => true }), 'conflict')
    assert_equal 'request_id_conflict', @transport.read('rejections/conflict.json')['error']['code']
    assert_equal 'success', @transport.read('results/test.json')['status']
    assert_equal 1, @adapter.calls
  end
  def test_invalid_and_incompatible_requests_do_not_block
    send_request(request.merge('protocol_version' => 2), 'badversion')
    assert_equal 'unsupported_version', @transport.read('rejections/badversion.json')['error']['code']
    send_request(request.merge('session_id' => 'old'), 'stale')
    assert_equal 'stale_session', @transport.read('rejections/stale.json')['error']['code']
    send_request(request.merge('model_token' => 'other'), 'othermodel')
    assert_equal 'model_mismatch', @transport.read('rejections/othermodel.json')['error']['code']
    File.write(File.join(@dir, 'inbox', 'incomplete.tmp'), '{')
    File.write(File.join(@dir, 'inbox', 'malformed.json'), '{')
    @transport.tick
    assert_equal 'rejected', @transport.read('rejections/malformed.json')['status']
    send_request(request('good'), 'good')
    assert_equal 1, @adapter.calls
  end
  def test_unknown_recovery_without_reexecution
    r = request('interrupted')
    @transport.atomic_write('journal/interrupted.json', { 'status' => 'claimed', 'fingerprint' => CodexSketchupBridge::Protocol.fingerprint(r), 'request' => r })
    @transport.stop
    @transport = CodexSketchupBridge::Transport.new(@dir, @adapter).start
    assert_equal 'outcome_unknown', @transport.read('results/interrupted.json')['status']
    send_request(r, 'retry')
    assert_equal 0, @adapter.calls
  end
  def test_result_written_before_crash_is_preserved
    r = request('saved')
    @transport.atomic_write('journal/saved.json', { 'status' => 'claimed', 'fingerprint' => CodexSketchupBridge::Protocol.fingerprint(r), 'request' => r })
    @transport.atomic_write('results/saved.json', { 'status' => 'success', 'data' => 42 })
    @transport.stop
    @transport = CodexSketchupBridge::Transport.new(@dir, @adapter).start
    assert_equal 42, @transport.read('results/saved.json')['data']
  end
  def test_lock_stop_and_path_boundaries
    competing = CodexSketchupBridge::Transport.new(@dir, @adapter)
    assert_raises(CodexSketchupBridge::BridgeError) { competing.start }
    assert_raises(CodexSketchupBridge::BridgeError) { @transport.safe_path('exports/../../outside') }
    @transport.stop
    send_request(request)
    assert_equal 0, @adapter.calls
    assert_equal false, @transport.read('session.json')['enabled']
  end
  def test_execution_error_then_recovery
    send_request(request('failure', { 'fail' => true }))
    assert_equal 'error', @transport.read('results/failure.json')['status']
    send_request(request('good'), 'good')
    assert_equal 'success', @transport.read('results/good.json')['status']
  end
  def test_ordered_queue_and_clear_preserves_models
    @transport.atomic_write('inbox/002.json', request('second'))
    @transport.atomic_write('inbox/001.json', request('first'))
    @transport.tick
    assert_equal 1, @transport.read('results/first.json')['data']['calls']
    refute File.exist?(File.join(@dir, 'results', 'second.json'))
    @transport.tick
    assert_equal 2, @transport.read('results/second.json')['data']['calls']
    File.write(File.join(@dir, 'keep.skp'), 'model')
    File.write(File.join(@dir, 'exports', 'keep.png'), 'image')
    @transport.stop
    @transport.clear_completed
    assert File.exist?(File.join(@dir, 'keep.skp'))
    assert File.exist?(File.join(@dir, 'exports', 'keep.png'))
    assert_empty Dir.children(File.join(@dir, 'journal'))
  end

  def test_timestamp_validation_without_date_extension
    protocol = CodexSketchupBridge::Protocol
    assert protocol.valid_timestamp?(protocol.timestamp)
    assert protocol.valid_timestamp?('2024-02-29T12:30:00+08:00')
    refute protocol.valid_timestamp?('2026-02-29T12:30:00Z')
    refute protocol.valid_timestamp?('2026-10-05T24:00:00Z')
    refute protocol.valid_timestamp?('2026-10-05T12:00:00+25:00')
  end

  def test_windows_path_forms_are_rejected_on_all_platforms
    ['..\\escape', 'C:/escape', 'C:escape', '/escape', '//server/share',
     'results/id.json:stream', 'results/CON.json', 'results/LPT1',
     'results/id.', 'a//b', 'a/./b'].each do |path|
      assert_raises(CodexSketchupBridge::BridgeError) { @transport.safe_path(path) }
    end
  end

  def test_utf8_content_roundtrips_in_unicode_directory
    root = File.join(@dir, '中文 空間')
    transport = CodexSketchupBridge::Transport.new(root, @adapter).start
    transport.atomic_write('results/unicode.json', { 'name' => '客廳 櫃體', 'line' => "a\nb" })
    assert_equal({ 'name' => '客廳 櫃體', 'line' => "a\nb" }, transport.read('results/unicode.json'))
    assert_equal Encoding::UTF_8, transport.read('results/unicode.json')['name'].encoding
  ensure
    transport&.stop
  end

  def test_directory_lock_across_processes
    code = <<~'RUBY'
      require ARGV.shift
      begin
        CodexSketchupBridge::Transport.new(ARGV.shift, Object.new).start
        abort 'Lock unexpectedly acquired'
      rescue CodexSketchupBridge::BridgeError => error
        abort error.message unless error.code == 'directory_busy'
        puts error.code
      end
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, '-e', code,
      File.expand_path('../extension/codex_sketchup_bridge/transport.rb', __dir__), @dir)
    assert status.success?, err
    assert_equal 'directory_busy', out.strip
  end

  def test_symlink_or_windows_junction_is_rejected
    target = File.join(@dir, 'target')
    link = File.join(@dir, 'exports', 'escape')
    Dir.mkdir(target)
    if Gem.win_platform?
      _out, err, status = Open3.capture3('cmd', '/d', '/c', 'mklink', '/J', link.tr('/', '\\'), target.tr('/', '\\'))
      assert status.success?, err
    else
      File.symlink(target, link)
    end
    assert_raises(CodexSketchupBridge::BridgeError) { @transport.safe_path('exports/escape/a.png') }
  ensure
    if link && File.symlink?(link)
      Gem.win_platform? ? Dir.rmdir(link) : File.unlink(link)
    end
  end

  def test_serialization_guards
    assert_raises(CodexSketchupBridge::BridgeError) { CodexSketchupBridge::Protocol.json_value!(Float::NAN) }
    assert_raises(CodexSketchupBridge::BridgeError) { CodexSketchupBridge::Protocol.json_value!(Object.new) }
  end
end
