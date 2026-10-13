require 'sketchup.rb'
require 'extensions.rb'

module CodexSketchupBridge
  VERSION = '0.1.0' unless const_defined?(:VERSION)
  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new('Codex SketchUp Bridge', 'codex_sketchup_bridge/main')
    extension.description = '透過本機 JSON 佇列查詢及操作 SketchUp。'
    extension.version = VERSION
    extension.creator = 'Codex SketchUp Bridge'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
