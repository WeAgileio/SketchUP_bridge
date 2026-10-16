require_relative 'protocol'
require 'fileutils'

module CodexSketchupBridge
  class Transport
    DIRECTORIES = %w[inbox processing results rejections journal exports].freeze
    NOFOLLOW = File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0
    WINDOWS = RUBY_PLATFORM.match?(/mswin|mingw/)
    RESERVED_NAME = /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)/i
    attr_reader :root, :session_id

    def initialize(root, adapter)
      @root = File.expand_path(root)
      @adapter = adapter
      @session_id = SecureRandom.uuid
      @enabled = false
    end

    def safe_path(relative)
      Protocol.fail!('invalid_path', 'Relative path required') unless relative.is_a?(String) && !relative.empty?
      parts = relative.split('/', -1)
      Protocol.fail!('invalid_path', 'Unsafe path') if parts.any? { |p| !p.match?(/\A[a-zA-Z0-9_.-]+\z/) || p == '.' || p == '..' || p.end_with?('.') || RESERVED_NAME.match?(p) }
      current = @root
      # Include root ancestors: do not follow a substituted symlink.
      ancestors = []
      loop do
        ancestors << current
        parent = File.dirname(current)
        break if parent == current
        current = parent
      end
      ancestors.each { |p| Protocol.fail!('invalid_path', "Symbolic link: #{p}") if File.symlink?(p) }
      current = @root
      parts.each do |part|
        current = File.join(current, part)
        Protocol.fail!('invalid_path', "Symbolic link: #{current}") if File.symlink?(current)
      end
      current
    end

    def atomic_write(relative, data)
      path = safe_path(relative)
      json = JSON.generate(Protocol.json_value!(data))
      Protocol.fail!('result_too_large', 'Result exceeds 1 MiB; use pagination') if json.bytesize > Protocol::MAX_BYTES
      temp = safe_path("#{relative}.#{SecureRandom.hex(8)}.tmp")
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.binmode
        file.write(json)
        file.flush
        file.fsync
      end
      rename_file(temp, path)
    ensure
      File.delete(temp) if temp && File.exist?(temp)
    end

    def rename_file(source, destination)
      retries = 0
      begin
        File.rename(source, destination)
      rescue Errno::EACCES, Errno::EPERM
        # Windows cannot replace a file during even a short read. Retry only
        # this filesystem step, never the request or model operation.
        raise unless WINDOWS && retries < 10
        retries += 1
        sleep 0.02
        retry
      end
    end

    def read(relative)
      path = safe_path(relative)
      File.open(path, File::RDONLY | NOFOLLOW) do |file|
        file.binmode
        Protocol.fail!('invalid_request', 'File exceeds 1 MiB') if file.size > Protocol::MAX_BYTES
        JSON.parse(file.read(Protocol::MAX_BYTES + 1).force_encoding(Encoding::UTF_8))
      end
    end

    def start
      Protocol.fail!('already_enabled', 'Bridge already enabled') if @enabled
      safe_path('session.json')
      FileUtils.mkdir_p(@root, mode: 0o700)
      DIRECTORIES.each do |dir|
        FileUtils.mkdir_p(safe_path(dir), mode: 0o700)
      end
      @lock = File.open(safe_path('bridge.lock'), File::RDWR | File::CREAT | NOFOLLOW, 0o600)
      Protocol.fail!('directory_busy', 'Another SketchUp instance owns this directory') unless @lock.flock(File::LOCK_EX | File::LOCK_NB)
      File.chmod(0o700, @root)
      DIRECTORIES.each { |dir| File.chmod(0o700, safe_path(dir)) }
      @enabled = true
      recover
      heartbeat
      self
    rescue StandardError
      @enabled = false
      @lock.close if @lock && !@lock.closed?
      raise
    end

    def stop
      return unless @enabled
      @enabled = false
      heartbeat
    ensure
      @lock.close if @lock && !@lock.closed?
    end

    def heartbeat
      atomic_write('session.json', @adapter.state.merge(
        'protocol_version' => Protocol::VERSION, 'session_id' => @session_id,
        'enabled' => @enabled, 'heartbeat_at' => CodexSketchupBridge::Protocol.timestamp,
        'pid' => Process.pid, 'capabilities' => @adapter.capabilities
      ))
    end

    def result(request, status, data = nil, error = nil)
      state = @adapter.state
      {
        'request_id' => request['request_id'], 'session_id' => request['session_id'],
        'model_token' => request['model_token'], 'protocol_version' => Protocol::VERSION,
        'status' => status, 'revision' => state['revision'],
        'current_model_token' => state['model_token'], 'data' => data,
        'warnings' => [], 'error' => error, 'completed_at' => CodexSketchupBridge::Protocol.timestamp
      }
    end

    def recover
      Dir.children(safe_path('journal')).sort.each do |name|
        next unless name.match?(/\A[a-zA-Z0-9_-]{1,80}\.json\z/)
        record = read("journal/#{name}")
        next unless record['status'] == 'claimed'
        response = if File.exist?(safe_path("results/#{name}"))
                     read("results/#{name}")
                   else
                     result(record.fetch('request'), 'outcome_unknown', nil,
                            { 'code' => 'outcome_unknown', 'message' => 'Interrupted request; inspect model before further changes' })
                   end
        atomic_write("results/#{name}", response)
        atomic_write("journal/#{name}", record.merge('status' => 'done'))
      end
      # Claims left behind are never replayed.
      Dir.children(safe_path('processing')).each do |name|
        next unless name.end_with?('.json')
        File.delete(safe_path("processing/#{name}"))
      end
    end

    def tick
      return unless @enabled
      heartbeat
      return if @processing
      @processing = true
      file = Dir.children(safe_path('inbox')).select { |n| n.match?(/\A[a-zA-Z0-9_-]{1,100}\.json\z/) }.sort.first
      process(file) if file
      heartbeat
    ensure
      @processing = false
    end

    def process(file)
      request = nil
      claimed = false
      executed = false
      moved = false
      begin
        rename_file(safe_path("inbox/#{file}"), safe_path("processing/#{file}"))
        moved = true
        request = read("processing/#{file}")
        Protocol.validate!(request)
        id = request.fetch('request_id')
        fingerprint = Protocol.fingerprint(request)
        journal_path = "journal/#{id}.json"
        if File.exist?(safe_path(journal_path))
          old = read(journal_path)
          Protocol.fail!('request_id_conflict', 'request_id already belongs to different content') unless old['fingerprint'] == fingerprint
          return # Original result remains available, including outcome_unknown.
        end
        Protocol.fail!('stale_session', 'Session no longer active') unless request['session_id'] == @session_id
        @adapter.validate_target!(request)
        atomic_write(journal_path, { 'status' => 'claimed', 'fingerprint' => fingerprint, 'request' => request })
        claimed = true
        response = @adapter.execute(request, self)
        executed = true
        atomic_write("results/#{id}.json", result(request, 'success', response))
        atomic_write(journal_path, { 'status' => 'done', 'fingerprint' => fingerprint, 'request' => request })
      rescue StandardError, SyntaxError => error
        code = executed ? 'outcome_unknown' : (error.is_a?(BridgeError) ? error.code : 'execution_error')
        status = executed ? 'outcome_unknown' : (claimed ? 'error' : 'rejected')
        response = result(request.is_a?(Hash) ? request : {}, status, nil,
                          { 'code' => code, 'message' => error.message, 'type' => error.class.name })
        if claimed
          atomic_write("results/#{id}.json", response)
          atomic_write(journal_path, { 'status' => 'done', 'fingerprint' => fingerprint, 'request' => request })
        else
          # Receipt-scoped rejection cannot overwrite the original ID's result.
          atomic_write("rejections/#{file}", response)
        end
      ensure
        File.delete(safe_path("processing/#{file}")) if moved && File.exist?(safe_path("processing/#{file}"))
      end
    end

    def clear_completed
      Protocol.fail!('still_enabled', 'Stop bridge before clearing completed records') if @enabled
      %w[results rejections journal].each do |dir|
        Dir.children(safe_path(dir)).each do |name|
          next unless name.match?(/\A[a-zA-Z0-9_-]{1,100}\.json\z/)
          record = read("#{dir}/#{name}")
          next if dir == 'journal' && record['status'] != 'done'
          File.delete(safe_path("#{dir}/#{name}"))
        end
      end
    end
  end
end
