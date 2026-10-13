require 'sketchup.rb'
require_relative 'transport'
require_relative 'model_adapter'

module CodexSketchupBridge
  class << self
    attr_reader :transport, :adapter

    def enable(directory = nil)
      raise BridgeError.new('already_enabled', '先停用目前橋接') if @timer
      directory ||= UI.select_directory(title: '選擇 Codex 橋接資料夾', directory: Sketchup.read_default('CodexSketchupBridge', 'directory', ''))
      return unless directory
      @adapter ||= ModelAdapter.new
      @transport = Transport.new(directory, @adapter).start
      Sketchup.write_default('CodexSketchupBridge', 'directory', directory)
      @timer = UI.start_timer(0.5, true) do
        begin
          @transport.tick
        rescue StandardError => error
          warn("Codex bridge stopped: #{error.class}: #{error.message}")
          disable
          UI.messagebox("Codex 橋接已停用：#{error.message}")
        end
      end
      true
    end

    def disable
      UI.stop_timer(@timer) if @timer
      @timer = nil
      @transport.stop if @transport
    end

    def trusted_ruby
      @adapter ||= ModelAdapter.new
      if @adapter.trusted_ruby
        @adapter.trusted_ruby = false
      else
        answer = UI.messagebox('Ruby 腳本可操作本機檔案與程序，無沙箱。只執行你信任的 Codex 腳本。是否啟用？', MB_YESNO)
        @adapter.trusted_ruby = true if answer == IDYES
      end
      @transport.heartbeat if @timer
    end

    def status
      @adapter ||= ModelAdapter.new
      UI.messagebox(JSON.pretty_generate(@adapter.state.merge('enabled' => !!@timer, 'directory' => @transport&.root)))
    end

    def clear_completed
      raise BridgeError.new('still_enabled', '先停用橋接再清除紀錄') if @timer
      return unless @transport
      answer = UI.messagebox('清除完成的結果與去重紀錄？清除後舊 request_id 不再受去重保護；模型與匯出影像不會刪除。', MB_YESNO)
      @transport.clear_completed if answer == IDYES
    end

    def safely
      yield
    rescue StandardError => error
      UI.messagebox("Codex 橋接：#{error.message}")
    end
  end

  unless file_loaded?(__FILE__)
    menu = UI.menu('Extensions').add_submenu('Codex SketchUp Bridge')
    menu.add_item('啟用橋接…') { safely { enable } }
    menu.add_item('停用橋接') { safely { disable } }
    menu.add_item('切換受信任 Ruby 模式') { safely { trusted_ruby } }
    menu.add_item('連線狀態') { safely { status } }
    menu.add_item('清除已完成紀錄…') { safely { clear_completed } }
    file_loaded(__FILE__)
  end
end
