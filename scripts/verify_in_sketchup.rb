# Run from SketchUp Ruby Console after creating a separate new model.
require 'json'
require 'securerandom'
require 'fileutils'

module CodexBridgeVerification
  ROOT = File.expand_path('..', __dir__)
  REPORT = File.join(ROOT, 'verification', 'sketchup-results.json')
  class << self
    def assert(condition, message)
      raise message unless condition
    end
    def check(name)
      yield
      @checks << { 'name' => name, 'status' => 'passed' }
    rescue StandardError, SyntaxError => e
      @checks << { 'name' => name, 'status' => 'failed', 'error' => "#{e.class}: #{e.message}" }
      raise
    ensure
      File.write(REPORT, JSON.pretty_generate('checks' => @checks, 'runtime' => @adapter&.state))
    end
    def call(action, args = {}, overrides = {})
      @counter += 1
      state = @adapter.state
      req = { 'request_id' => "verify-#{@prefix}-#{@counter}", 'protocol_version' => 1,
              'session_id' => @transport.session_id, 'model_token' => state['model_token'],
              'expected_revision' => state['revision'], 'action' => action,
              'arguments' => args, 'submitted_at' => CodexSketchupBridge::Protocol.timestamp }.merge(overrides)
      name = "v-#{@prefix}-#{@counter}.json"
      @transport.atomic_write("inbox/#{name}", req)
      @transport.tick
      response = if File.exist?(@transport.safe_path("rejections/#{name}"))
                   @transport.read("rejections/#{name}")
                 else
                   @transport.read("results/#{req['request_id']}.json")
                 end
      @last_request = req
      response
    end
    def success(action, args = {})
      response = call(action, args)
      assert(response['status'] == 'success', "#{action}: #{response.inspect}")
      response.fetch('data')
    end
    def near(a, b)
      a.zip(b).all? { |x,y| (x-y).abs < 0.001 }
    end
    def run
      @checks = []; @counter = 0; @prefix = SecureRandom.hex(4)
      @adapter = CodexSketchupBridge.adapter
      @transport = CodexSketchupBridge.transport
      m = Sketchup.active_model
      assert(m.path.empty?, 'Verification must use a new unsaved model')
      assert(m.get_attribute('CodexBridgeVerification', 'fixture') == true, 'Create the designated verification model first')
      assert(@adapter && @transport, 'Enable the bridge before verification')
      assert(!File.exist?(File.join(ROOT, 'verification', 'bridge-verification.skp')), 'Existing verification model must be moved before rerunning')
      FileUtils.mkdir_p(File.dirname(REPORT))
      m.select_tool(nil)
      check('runtime_and_queries') do
        info = success('model_info')
        assert(info['ruby_version'] == RUBY_VERSION, 'Ruby runtime mismatch')
        %w[selection materials tags definitions camera].each { |a| success(a) }
        assert(success('list_entities', 'limit' => 1)['entities'].length <= 1, 'Pagination failed')
      end
      check('groups_components_units_and_isolation') do
        @box = success('create_box', 'parent' => [], 'unit' => 'cm', 'origin' => [0,0,0], 'size' => [120,60,75], 'name' => '驗證盒體')['entity']
        assert(near(@box['world_bounds']['size'], [1200,600,750]), 'Wrong cm box dimensions')
        @mm = success('create_box', 'parent' => [], 'unit' => 'mm', 'origin' => [1500,0,0], 'size' => [1200,600,750], 'name' => '毫米盒體')['entity']
        assert(near(@mm['world_bounds']['size'], [1200,600,750]), 'Wrong mm box dimensions')
        @group = success('create_group', 'parent' => [], 'name' => '巢狀群組')['entity']
        @component = success('create_component', 'parent' => @group['path'], 'name' => '元件')['entity']
        @face = success('create_face', 'parent' => @component['path'], 'unit' => 'mm', 'points' => [[0,0,0],[100,0,0],[100,100,0],[0,100,0]])['entity']
        success('pushpull', 'path' => @face['path'], 'unit' => 'mm', 'distance' => 200)
        content = success('list_entities', 'parent' => @component['path'])
        assert(content['total'] >= 6, 'Pushpull did not form a solid')
      end
      check('transforms_properties_and_world_bounds') do
        moved = success('transform', 'path' => @group['path'], 'mode' => 'translate', 'unit' => 'mm', 'vector' => [0,1500,0])['entity']
        assert((moved['world_bounds']['min'][1] - 1500).abs < 0.001, 'Translation mismatch')
        success('transform', 'path' => @group['path'], 'mode' => 'rotate', 'unit' => 'mm', 'origin' => [0,1500,0], 'axis' => [0,0,1], 'degrees' => 90)
        success('transform', 'path' => @group['path'], 'mode' => 'scale', 'unit' => 'mm', 'origin' => [0,1500,0], 'factors' => [2,2,2])
        nested = success('list_entities', 'parent' => @component['path'])['entities']
        assert(nested.all? { |e| e['path'].length == 3 }, 'Instance paths missing')
        changed = success('set_properties', 'path' => @box['path'], 'name' => '已修改', 'tag' => 'Bridge Test', 'material' => { 'name' => 'Bridge Test Blue', 'color' => [60,120,200], 'alpha' => 1.0 })['entity']
        assert(changed['name'] == '已修改' && changed['tag'] == 'Bridge Test' && changed['material'] == 'Bridge Test Blue', 'Properties mismatch')
      end
      check('stale_revision_missing_entity_and_model_rejection') do
        state = @adapter.state
        response = call('create_group', { 'parent' => [] }, 'expected_revision' => [state['revision']-1, 0].max)
        assert(response.dig('error', 'code') == 'stale_revision', 'Stale revision accepted')
        response = call('create_group', { 'parent' => [] }, 'model_token' => 'other-model')
        assert(response.dig('error', 'code') == 'model_mismatch', 'Wrong model accepted')
        response = call('set_properties', { 'path' => [999999999], 'name' => 'missing' })
        assert(response.dig('error', 'code') == 'entity_missing', 'Missing entity accepted')
      end
      check('shared_component_scope_and_copy_on_write') do
        definition = m.definitions.add('Shared verification')
        definition.entities.add_face([0,0,0],[20,0,0],[20,20,0],[0,20,0])
        m.start_operation('Independent shared fixture', true)
        one = m.entities.add_instance(definition, Geom::Transformation.translation([0,100,0]))
        two = m.entities.add_instance(definition, Geom::Transformation.translation([50,100,0]))
        m.commit_operation
        response = call('create_box', { 'parent' => [one.persistent_id], 'unit' => 'mm', 'origin' => [0,0,0], 'size' => [10,10,10] })
        assert(response.dig('error', 'code') == 'ambiguous_scope', 'Ambiguous shared definition accepted')
        old_count = two.definition.entities.length
        success('create_box', 'parent' => [one.persistent_id], 'scope' => 'instance', 'unit' => 'mm', 'origin' => [0,0,0], 'size' => [10,10,10])
        assert(one.definition != two.definition, 'Instance not made unique')
        assert(two.definition.entities.length == old_count, 'Other instance modified')
        # Shared ancestor containing a nested instance: ensure copied child path resolves.
        parent_definition = m.definitions.add('Shared parent verification')
        child_definition = m.definitions.add('Shared child verification')
        child_definition.entities.add_face([0,0,0],[10,0,0],[10,10,0],[0,10,0])
        child = parent_definition.entities.add_instance(child_definition, Geom::Transformation.new)
        m.start_operation('Independent nested fixture', true)
        p1 = m.entities.add_instance(parent_definition, Geom::Transformation.new)
        p2 = m.entities.add_instance(parent_definition, Geom::Transformation.translation([100,100,0]))
        m.commit_operation
        original_child_count = child_definition.entities.length
        result = success('create_box', 'parent' => [p1.persistent_id, child.persistent_id], 'scope' => 'instance', 'unit' => 'mm', 'origin' => [0,0,0], 'size' => [10,10,10])
        assert(result['entity']['path'].length == 3, 'Copied nested path invalid')
        assert(p1.definition != p2.definition, 'Nested parent not unique')
        assert(child_definition.entities.length == original_child_count, 'Shared nested definition modified')
        # Explicit definition scope affects both remaining shared instances.
        three = m.entities.add_instance(two.definition, Geom::Transformation.new)
        success('create_box', 'parent' => [two.persistent_id], 'scope' => 'definition', 'unit' => 'mm', 'origin' => [0,0,0], 'size' => [10,10,10])
        assert(two.definition == three.definition && three.definition.entities.length > old_count, 'Definition scope mismatch')
      end
      check('undo_redo_and_independent_modification_revision') do
        before = m.entities.length
        revision = @adapter.state['revision']
        success('create_box', 'parent' => [], 'unit' => 'mm', 'origin' => [0,0,0], 'size' => [10,10,10])
        assert(m.entities.length == before+1, 'Box missing')
        Sketchup.undo
        assert(m.entities.length == before, 'Single Undo failed')
        assert(@adapter.state['revision'] > revision, 'Undo revision unchanged')
        Sketchup.redo
        assert(m.entities.length == before+1, 'Redo failed')
        old = @adapter.state['revision']
        m.start_operation('Independent manual-style change', true)
        m.entities.add_line([0,0,0], [1,0,0])
        m.commit_operation
        assert(@adapter.state['revision'] > old, 'Outside modification unobserved')
        response = call('create_group', { 'parent' => [] }, 'expected_revision' => old)
        assert(response.dig('error', 'code') == 'stale_revision', 'Outside modification stale revision accepted')
      end
      check('ruby_gate_failure_abort_and_serialization') do
        @adapter.trusted_ruby = false
        response = call('execute_ruby', { 'script' => 'result = 42' })
        assert(response.dig('error', 'code') == 'ruby_disabled', 'Ruby gate missing')
        # Test-only direct adapter flag, restored in ensure. Does not enable production mode.
        @adapter.trusted_ruby = true
        before = m.entities.length
        response = call('execute_ruby', { 'script' => 'model.entities.add_group; raise "intentional failure"' })
        assert(response['status'] == 'error' && m.entities.length == before, 'Failure did not abort')
        response = call('execute_ruby', { 'script' => 'model.entities.add_group; result = Object.new' })
        assert(response.dig('error','code') == 'invalid_result' && m.entities.length == before, 'Invalid result did not abort')
        assert(success('execute_ruby', 'script' => 'result = {"runtime" => RUBY_VERSION, "ok" => true}')['ok'], 'Ruby result failed')
        @adapter.trusted_ruby = false
        success('delete_entities', 'path' => @mm['path'])
        response = call('set_properties', { 'path' => @mm['path'], 'name' => 'deleted' })
        assert(response.dig('error','code') == 'entity_missing', 'Deleted entity still resolves')
      end
      check('view_export') do
        m.active_view.zoom_extents
        result = success('export_view', 'filename' => "verification-#{@prefix}.png", 'width' => 1200, 'height' => 900)
        assert(File.size(result['path']) > 0, 'PNG missing')
        @image = result['path']
      end
      check('enable_disable_persistence_and_restart') do
        directory = @transport.root
        session = @transport.session_id
        assert(Sketchup.read_default('CodexSketchupBridge', 'directory') == directory, 'Directory not persisted')
        CodexSketchupBridge.disable
        assert(JSON.parse(File.read(File.join(directory, 'session.json')))['enabled'] == false, 'Disabled heartbeat wrong')
        CodexSketchupBridge.enable(directory)
        @transport = CodexSketchupBridge.transport
        assert(@transport.session_id != session, 'Session not rotated')
        response = call('create_group', { 'parent' => [] }, 'session_id' => session)
        assert(response.dig('error','code') == 'stale_session', 'Old session accepted')
      end
      m.save(File.join(ROOT, 'verification', 'bridge-verification.skp'))
      File.write(REPORT, JSON.pretty_generate('checks' => @checks, 'runtime' => @adapter.state, 'image' => @image,
                                             'model' => m.path, 'completed_at' => CodexSketchupBridge::Protocol.timestamp))
      puts "VERIFICATION PASSED: #{@checks.length} checks. #{REPORT}"
      true
    rescue StandardError, SyntaxError => e
      puts "VERIFICATION FAILED: #{e.class}: #{e.message}"
      puts e.backtrace.take(8)
      false
    ensure
      @adapter.trusted_ruby = false if @adapter
    end
  end
end
CodexBridgeVerification.run
