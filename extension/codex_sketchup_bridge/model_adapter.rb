require_relative 'protocol'

module CodexSketchupBridge
  class ModelChanges < Sketchup::ModelObserver
    def initialize(adapter); @adapter = adapter; end
    %i[onTransactionCommit onTransactionUndo onTransactionRedo onTransactionAbort onActivePathChanged].each do |event|
      define_method(event) { |model| @adapter.changed(model) }
    end
    def onDeleteModel(model); @adapter.forget(model); end
  end

  class AppChanges < Sketchup::AppObserver
    def initialize(adapter); @adapter = adapter; end
    def expectsStartupModelNotifications; true; end
    def onNewModel(model); @adapter.attach(model); end
    def onOpenModel(model); @adapter.attach(model); end
    def onActivateModel(model); @adapter.attach(model); end
    def onQuit; CodexSketchupBridge.disable; end
  end

  class ModelAdapter
    READ_ACTIONS = %w[model_info list_entities selection materials tags definitions camera export_view].freeze
    WRITE_ACTIONS = %w[create_group create_component create_face create_box pushpull transform set_properties delete_entities execute_ruby].freeze
    FACTORS = { 'mm' => 1.0 / 25.4, 'cm' => 1.0 / 2.54, 'm' => 1000.0 / 25.4, 'inch' => 1.0 }.freeze
    attr_accessor :trusted_ruby

    def initialize
      @models = {}
      @trusted_ruby = false
      @app_observer = AppChanges.new(self)
      Sketchup.add_observer(@app_observer)
      attach(Sketchup.active_model)
    end

    def attach(model)
      return if !model || @models.key?(model)
      observer = ModelChanges.new(self)
      @models[model] = { token: SecureRandom.uuid, revision: 0, observer: observer }
      model.add_observer(observer)
    end

    def changed(model)
      attach(model)
      @models[model][:revision] += 1
    end

    def forget(model); @models.delete(model); end

    def state
      model = Sketchup.active_model
      attach(model)
      { 'model_token' => @models.fetch(model)[:token], 'revision' => @models.fetch(model)[:revision],
        'sketchup_version' => Sketchup.version, 'ruby_version' => RUBY_VERSION,
        'trusted_ruby' => @trusted_ruby }
    end

    def capabilities; READ_ACTIONS + WRITE_ACTIONS; end

    def validate_target!(request)
      current = state
      Protocol.fail!('model_mismatch', 'Refresh state: target model changed') unless request['model_token'] == current['model_token']
      if WRITE_ACTIONS.include?(request['action'])
        Protocol.fail!('stale_revision', 'Refresh state: model was modified') unless request['expected_revision'] == current['revision']
      end
      Protocol.fail!('unknown_action', 'Action not supported') unless capabilities.include?(request['action'])
      # Native edit context changes API coordinates. Require closing it rather than silently misplacing geometry.
      Protocol.fail!('editing_context', 'Close the active group/component edit context before bridge operations') if Sketchup.active_model.active_path
      if WRITE_ACTIONS.include?(request['action']) && Sketchup.active_model.tools.active_tool_name != 'SelectionTool'
        Protocol.fail!('native_tool_active', 'Activate the Select tool before modifying through the bridge')
      end
    end

    def execute(request, transport)
      model = Sketchup.active_model
      action = request.fetch('action')
      args = request.fetch('arguments')
      return query(action, args, model, transport) if READ_ACTIONS.include?(action)
      Protocol.fail!('ruby_disabled', 'Enable trusted Ruby mode in the extension menu') if action == 'execute_ruby' && !@trusted_ruby
      model.start_operation("Codex: #{action}", true)
      begin
        data = mutate(action, args, model)
        Protocol.json_value!(data)
        Protocol.fail!('result_too_large', 'Result exceeds 1 MiB') if JSON.generate(data).bytesize > 900_000
        model.commit_operation
        data
      rescue StandardError, SyntaxError
        model.abort_operation
        raise
      end
    end

    def number(value)
      Protocol.fail!('invalid_arguments', 'Expected finite numeric value') unless value.is_a?(Numeric) && value.to_f.finite?
      value.to_f
    end

    def factor(args)
      FACTORS.fetch(args['unit']) { Protocol.fail!('invalid_arguments', 'unit must be mm, cm, m or inch') }
    end

    def vector(value, multiplier = 1.0)
      Protocol.fail!('invalid_arguments', 'Expected [x,y,z]') unless value.is_a?(Array) && value.length == 3
      value.map { |v| number(v) * multiplier }
    end

    def container?(entity)
      entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
    end

    def contents(entity); entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities; end

    def resolve(model, path)
      Protocol.fail!('invalid_arguments', 'path must contain positive persistent IDs') unless path.is_a?(Array) && path.all? { |id| id.is_a?(Integer) && id > 0 }
      entities = model.entities
      chain = []
      path.each_with_index do |id, i|
        entity = entities.find { |e| e.valid? && e.persistent_id == id }
        Protocol.fail!('entity_missing', "Entity path not found: #{id}") unless entity
        chain << entity
        if i < path.length - 1
          Protocol.fail!('invalid_arguments', 'Intermediate path member is not a container') unless container?(entity)
          entities = contents(entity)
        end
      end
      chain
    end

    def prepare_path(model, path, scope, include_leaf)
      chain = resolve(model, path)
      Protocol.fail!('locked_entity', 'Target or ancestor is locked') if chain.any? { |e| e.respond_to?(:locked?) && e.locked? }
      limits = include_leaf ? chain.length : [chain.length - 1, 0].max
      shared = chain.take(limits).any? { |e| container?(e) && e.definition.instances.length > 1 }
      if shared
        Protocol.fail!('ambiguous_scope', 'scope must be instance or definition for shared component contents') unless %w[instance definition].include?(scope)
      elsif scope && !%w[instance definition].include?(scope)
        Protocol.fail!('invalid_arguments', 'Unknown scope')
      end
      return chain unless scope == 'instance'
      # Copy-on-write each shared ancestor. Child PIDs change when a definition is copied.
      chain.each_with_index do |entity, index|
        next unless index < limits && container?(entity) && entity.definition.instances.length > 1
        child_index = index + 1 < chain.length ? contents(entity).to_a.index(chain[index + 1]) : nil
        entity.make_unique
        next unless child_index
        chain[index + 1] = contents(entity).to_a.fetch(child_index)
        ((index + 2)...chain.length).each do |j|
          # Deeper definitions remain shared; their immediate entity IDs are preserved.
          chain[j] = contents(chain[j - 1]).find { |e| e.persistent_id == chain[j].persistent_id }
          Protocol.fail!('entity_missing', 'Could not resolve copied instance path') unless chain[j]
        end
      end
      chain
    end

    def parent_entities(model, args)
      Protocol.fail!('invalid_arguments', 'parent must be a path array; [] means model root') unless args.key?('parent')
      chain = prepare_path(model, args['parent'], args['scope'], true)
      return [model.entities, []] if chain.empty?
      Protocol.fail!('invalid_arguments', 'parent must resolve to a group/component') unless container?(chain.last)
      [contents(chain.last), chain.map(&:persistent_id)]
    end

    def bbox(bounds, transform = Geom::Transformation.new)
      box = Geom::BoundingBox.new
      8.times { |i| box.add(bounds.corner(i).transform(transform)) } unless bounds.empty?
      return nil if box.empty?
      { 'min' => box.min.to_a.map { |v| v.to_f * 25.4 },
        'max' => box.max.to_a.map { |v| v.to_f * 25.4 },
        'size' => [box.width, box.height, box.depth].map { |v| v.to_f * 25.4 } }
    end

    def describe(entity, parent_path = [], parent_transform = Geom::Transformation.new)
      data = { 'persistent_id' => entity.persistent_id, 'path' => parent_path + [entity.persistent_id],
               'type' => entity.typename, 'unit' => 'mm', 'parent_bounds' => bbox(entity.bounds),
               'world_bounds' => bbox(entity.bounds, parent_transform), 'bounds_kind' => 'axis_aligned',
               'name' => entity.respond_to?(:name) ? entity.name : nil,
               'material' => entity.respond_to?(:material) && entity.material ? entity.material.name : nil,
               'tag' => entity.respond_to?(:layer) ? entity.layer.name : nil,
               'hidden' => entity.respond_to?(:hidden?) ? entity.hidden? : nil,
               'bridge_placeholder' => entity.get_attribute('CodexSketchupBridge', 'placeholder', false) }
      if container?(entity)
        data.merge!('definition_id' => entity.definition.persistent_id,
                    'definition_name' => entity.definition.name,
                    'definition_instances' => entity.definition.instances.length,
                    'definition_bounds' => bbox(entity.definition.bounds),
                    'transform' => entity.transformation.to_a.map(&:to_f))
      end
      data
    end

    def query(action, args, model, transport)
      case action
      when 'model_info'
        state.merge('title' => model.title, 'path' => model.path, 'unit' => 'mm',
                    'root_entity_count' => model.entities.length, 'bounds' => bbox(model.bounds),
                    'axes' => { 'origin' => model.axes.origin.to_a.map { |v| v.to_f * 25.4 },
                                'x' => model.axes.xaxis.to_a, 'y' => model.axes.yaxis.to_a, 'z' => model.axes.zaxis.to_a })
      when 'list_entities'
        parent = args.fetch('parent', [])
        chain = resolve(model, parent)
        Protocol.fail!('invalid_arguments', 'parent must be a container') if !chain.empty? && !container?(chain.last)
        entities = chain.empty? ? model.entities : contents(chain.last)
        transform = chain.inject(Geom::Transformation.new) { |t, e| t * e.transformation }
        offset = args.fetch('offset', 0)
        limit = args.fetch('limit', 100)
        Protocol.fail!('invalid_arguments', 'Invalid pagination') unless offset.is_a?(Integer) && offset >= 0 && limit.is_a?(Integer) && (1..500).cover?(limit)
        list = entities.to_a.sort_by(&:persistent_id)
        { 'total' => list.length, 'offset' => offset, 'next_offset' => offset + limit < list.length ? offset + limit : nil,
          'entities' => list.slice(offset, limit).to_a.map { |e| describe(e, parent, transform) } }
      when 'selection'
        { 'entities' => model.selection.map { |e| describe(e) } }
      when 'materials'
        { 'materials' => model.materials.map { |m| { 'name' => m.name, 'color' => m.color.to_a, 'alpha' => m.alpha,
                                                    'texture' => m.texture ? m.texture.filename : nil } } }
      when 'tags'
        { 'tags' => model.layers.map { |l| { 'name' => l.name, 'visible' => l.visible? } } }
      when 'definitions'
        { 'definitions' => model.definitions.map { |d| { 'persistent_id' => d.persistent_id, 'name' => d.name,
                                                         'instances' => d.instances.length, 'bounds' => bbox(d.bounds), 'unit' => 'mm' } } }
      when 'camera'
        cam = model.active_view.camera
        { 'eye' => cam.eye.to_a.map { |v| v.to_f * 25.4 }, 'target' => cam.target.to_a.map { |v| v.to_f * 25.4 },
          'up' => cam.up.to_a, 'perspective' => cam.perspective?, 'fov' => cam.perspective? ? cam.fov : nil, 'unit' => 'mm' }
      when 'export_view'
        name = args.fetch('filename', "#{SecureRandom.uuid}.png")
        Protocol.fail!('invalid_path', 'filename must be a plain PNG filename') unless name.is_a?(String) && name.match?(/\A[a-zA-Z0-9_-]+\.png\z/)
        path = transport.safe_path("exports/#{name}")
        Protocol.fail!('file_exists', 'Export filename already exists') if File.exist?(path)
        width = args.fetch('width', 1200); height = args.fetch('height', 900)
        Protocol.fail!('invalid_arguments', 'Image size must be 64..4096') unless [width, height].all? { |v| v.is_a?(Integer) && (64..4096).cover?(v) }
        ok = model.active_view.write_image(filename: path, width: width, height: height, antialias: true, transparent: false)
        Protocol.fail!('export_failed', 'SketchUp did not create an image') unless ok && File.file?(path) && File.size(path) > 0
        { 'path' => path, 'width' => width, 'height' => height }
      end
    end

    def mutate(action, args, model)
      if action == 'execute_ruby'
        script = args.fetch('script')
        Protocol.fail!('invalid_arguments', 'script must be a string') unless script.is_a?(String)
        # Deliberately trusted, not sandboxed. Result is assigned by the script.
        result = nil
        eval(script, binding, 'codex-request.rb', 1)
        return result
      end
      if %w[create_group create_component create_face create_box].include?(action)
        entities, parent = parent_entities(model, args)
        case action
        when 'create_group', 'create_component'
          entity = entities.add_group
          marker = entity.entities.add_cpoint([0, 0, 0])
          marker.hidden = true
          marker.set_attribute('CodexSketchupBridge', 'placeholder', true)
          entity = entity.to_component if action == 'create_component'
          entity.name = args.fetch('name', '')
          entity.definition.name = args.fetch('definition_name', entity.name) if action == 'create_component'
        when 'create_face'
          points = args.fetch('points')
          Protocol.fail!('invalid_arguments', 'Expected 3..10000 points') unless points.is_a?(Array) && (3..10_000).cover?(points.length)
          entity = entities.add_face(points.map { |v| vector(v, factor(args)) })
          Protocol.fail!('invalid_geometry', 'Cannot create face') unless entity
        when 'create_box'
          unit = factor(args)
          origin = vector(args.fetch('origin'), unit)
          size = vector(args.fetch('size'), unit)
          Protocol.fail!('invalid_geometry', 'Box dimensions must be positive') unless size.all?(&:positive?)
          entity = entities.add_group
          entity.name = args.fetch('name', '')
          x, y, z = origin; w, d, h = size
          face = entity.entities.add_face([x,y,z], [x+w,y,z], [x+w,y+d,z], [x,y+d,z])
          Protocol.fail!('invalid_geometry', 'Cannot create box base') unless face
          face.reverse! if face.normal.z < 0
          face.pushpull(h)
        end
        entities.grep(Sketchup::ConstructionPoint).each do |point|
          point.erase! if point.get_attribute('CodexSketchupBridge', 'placeholder', false)
        end
        return { 'entity' => describe(entity, parent, resolve(model, parent).inject(Geom::Transformation.new) { |t,e| t * e.transformation }) }
      end
      path = args.fetch('path')
      Protocol.fail!('invalid_arguments', 'Target path cannot be empty') unless path.is_a?(Array) && !path.empty?
      chain = prepare_path(model, path, args['scope'], false)
      entity = chain.last
      Protocol.fail!('locked_entity', 'Target or ancestor is locked') if chain.any? { |e| e.respond_to?(:locked?) && e.locked? }
      case action
      when 'pushpull'
        Protocol.fail!('invalid_arguments', 'Target must be a Face') unless entity.is_a?(Sketchup::Face)
        entity.pushpull(number(args.fetch('distance')) * factor(args))
      when 'transform'
        Protocol.fail!('invalid_arguments', 'Target must be a group/component') unless container?(entity)
        mode = args.fetch('mode')
        transform = case mode
                    when 'translate' then Geom::Transformation.translation(vector(args.fetch('vector'), factor(args)))
                    when 'rotate'
                      Geom::Transformation.rotation(vector(args.fetch('origin'), factor(args)), vector(args.fetch('axis')), number(args.fetch('degrees')) * Math::PI / 180.0)
                    when 'scale'
                      values = vector(args.fetch('factors'))
                      Protocol.fail!('invalid_arguments', 'Scale factors cannot be zero') if values.any?(&:zero?)
                      Geom::Transformation.scaling(Geom::Point3d.new(vector(args.fetch('origin'), factor(args))), *values)
                    else Protocol.fail!('invalid_arguments', 'Unknown transform mode')
                    end
        # Transforms are expressed in parent coordinates, never inferred from camera.
        entity.transform!(transform)
      when 'set_properties'
        if args.key?('name')
          Protocol.fail!('invalid_arguments', 'Entity does not support name') unless entity.respond_to?(:name=)
          entity.name = args.fetch('name')
        end
        if args.key?('material')
          material_args = args.fetch('material')
          if material_args.nil?
            entity.material = nil
          else
            Protocol.fail!('invalid_arguments', 'material must be an object') unless material_args.is_a?(Hash)
            material = model.materials[material_args.fetch('name')] || model.materials.add(material_args.fetch('name'))
            material.color = material_args['color'] if material_args.key?('color')
            material.alpha = number(material_args['alpha']) if material_args.key?('alpha')
            entity.material = material
          end
        end
        entity.layer = model.layers[args['tag']] || model.layers.add(args['tag']) if args.key?('tag')
      when 'delete_entities'
        deleted_path = chain.map(&:persistent_id)
        entity.erase!
        return { 'deleted_path' => deleted_path }
      else
        Protocol.fail!('unknown_action', 'Action not supported')
      end
      parent = chain.take(chain.length - 1)
      { 'entity' => describe(entity, parent.map(&:persistent_id), parent.inject(Geom::Transformation.new) { |t,e| t * e.transformation }) }
    rescue KeyError => error
      Protocol.fail!('invalid_arguments', error.message)
    end
  end
end
