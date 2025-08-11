# QUIET
# barbar_helpers.rb - Helper methods for BarBar

module BarBar
  @@save_timer = nil
  @@pixbuf_cache = {}
  @@pixbuf_lru = []
  @@sprite_cache = {}
  @@sprite_lru = []
  @@compiled_expressions = {}
  @@expression_lru = []
  @@bar_windows  = []
  @@config       = {}
  @@disp_icon_w = ICON_WIDTH
  @@disp_icon_h = ICON_HEIGHT
  @@css_provider = Gtk::CssProvider.new
  @@debug = false
  @close_window = false
  @@config_save_pending = false
  @@config_save_timer = nil

  def self.load_button_configs
    unless File.exist?(BUTTON_CFG)
      log(:info, "No button file detected. Creating one.")
      return {}
    end
    @button_configs ||= File.exist?(BUTTON_CFG) ? YAML.load_file(BUTTON_CFG) : {}
  end

  def self.save_button_configs
    require 'fileutils'
    dir = File.dirname(BUTTON_CFG)
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    File.write(BUTTON_CFG, load_button_configs.to_yaml)
  end

  def self.config_for(key)
    load_button_configs
    @button_configs[key]
  end

  def self.config
    @@config
  end

  def self.apply_css
    dark = @@config.fetch('dark_mode', false)
    # Get global timer font size, default to half icon height
    timer_font_size = @@config.fetch('timer_font_size', nil) || (@@disp_icon_h / 2)

    base_css = if dark
                 <<~CSS
        window, button, menu {
          background-color: #2E2E2E;
          color:            #DDDDDD;
        }
        button {
          border-width: 0;
          padding:      0;
        }
      CSS
               else
                 ""
               end

    timer_css = <<~CSS
      .skillbar-timer {
        font-size: #{timer_font_size}px;
        font-weight: bold;
        color: yellow;
        background-color: transparent;
        background: none;
        border: none;
        padding: 1px 2px;
        text-shadow: 1px 1px 2px rgba(0,0,0,0.8), -1px -1px 2px rgba(0,0,0,0.8);
      }
      .skillbar-timer-critical {
        color: #FF5555;
      }
    CSS

    reset_css = <<~CSS
      button {
        padding: 0;
        border-width: 0;
      }
    CSS

    @@css_provider.load(data: base_css + timer_css + reset_css)
    screen = Gdk::Screen.default
    Gtk::StyleContext.add_provider_for_screen(
      screen,
      @@css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
  end

  def self.clear_pixbuf_cache
    @@sprite_cache.clear
    @@sprite_lru.clear
  end

  def self.manage_cache
    while @@pixbuf_cache.size > MAX_CACHE_SIZE
      oldest = @@pixbuf_lru.shift
      @@pixbuf_cache.delete(oldest) if oldest
    end
  end

  def self.get_sprite_sheet(base, variant)
    sprite_key = "#{base}#{variant}"

    # Check if we already have this sprite sheet
    if @@sprite_cache[sprite_key]
      # Move to end of LRU list (most recently used)
      @@sprite_lru.delete(sprite_key)
      @@sprite_lru.push(sprite_key)
      return @@sprite_cache[sprite_key]
    end

    # Load the sprite sheet
    file = File.join(ICON_FOLDER, "#{sprite_key}.png")
    return nil unless File.exist?(file)

    sprite = GdkPixbuf::Pixbuf.new(file: file)

    # Add to cache and LRU list
    @@sprite_cache[sprite_key] = sprite
    @@sprite_lru.push(sprite_key)

    # Evict oldest sprite sheet if cache is too large
    if @@sprite_lru.size > MAX_SPRITE_CACHE_SIZE
      oldest = @@sprite_lru.shift
      @@sprite_cache.delete(oldest)
      log(:debug, "Evicted sprite sheet: #{oldest}")
    end

    sprite
  end

  def self.create_icon(cfg, state_sym, width = @@disp_icon_w, height = @@disp_icon_h)
    begin
      states = cfg['states'] || {}
      state_cfg = states[state_sym.to_s] || {}

      base = cfg['image']
      variant = state_cfg['variant'] || ''
      icon_num = (state_cfg['icon'] || 1).to_i

      return Gtk::Image.new unless base

      manage_cache if @@pixbuf_cache.size > MAX_CACHE_SIZE

      # Create a unique key for this specific icon
      key = "#{base}#{variant}_#{icon_num}_#{width}x#{height}"

      # Check if we have this specific icon cached
      if @@pixbuf_cache[key]
        @@pixbuf_lru.delete(key)
        @@pixbuf_lru.push(key)
      else
        # Get the sprite sheet (from cache or load it)
        sprite_sheet = get_sprite_sheet(base, variant)
        return Gtk::Image.new unless sprite_sheet

        # Calculate position in sprite sheet
        idx = icon_num - 1
        cx = idx % ICONS_PER_ROW
        ry = idx / ICONS_PER_ROW

        # Crop out the specific icon
        crop = sprite_sheet.subpixbuf(
          cx * ICON_WIDTH,
          ry * ICON_HEIGHT,
          ICON_WIDTH,
          ICON_HEIGHT
        )

        # Scale if needed
        if width != ICON_WIDTH || height != ICON_HEIGHT
          @@pixbuf_cache[key] = crop.scale_simple(
            width,
            height,
            GdkPixbuf::InterpType::BILINEAR
          )
        else
          @@pixbuf_cache[key] = crop
        end
        @@pixbuf_lru.push(key)
        manage_cache

        log(:debug, "Cached icon: #{key}")
      end

      Gtk::Image.new(pixbuf: @@pixbuf_cache[key])
    rescue => e
      log(:error, "create_icon error: #{e}")
      Gtk::Image.new
    end
  end

  def self.compile_expression(expr)
    return nil if expr.nil? || expr.empty?

    # Check cache first
    if @@compiled_expressions[expr]
      @@expression_lru.delete(expr)
      @@expression_lru.push(expr)
      return @@compiled_expressions[expr]
    end

    # Compile the expression into a proc
    begin
      proc = eval("proc { #{expr} }")

      # Add to cache
      @@compiled_expressions[expr] = proc
      @@expression_lru.push(expr)

      # Manage cache size
      if @@expression_lru.size > MAX_COMPILED_EXPR_CACHE
        oldest = @@expression_lru.shift
        @@compiled_expressions.delete(oldest)
      end

      proc
    rescue => e
      log(:error, "Failed to compile expression '#{expr}': #{e}")
      nil
    end
  end

  def self.determine_state(cfg)
    states_cfg = cfg['states'] || {}

    # Quick check for common case - no conditions at all
    has_conditions = states_cfg.any? { |_, spec| spec['condition'] }
    return :inactive_unready unless has_conditions

    %i[active_ready active_unready inactive_ready inactive_unready].each do |state_sym|
      spec = states_cfg[state_sym.to_s] || {}
      cond = spec['condition']
      next unless cond
      next if cond.empty? || cond !~ /\S/

      proc = compile_expression(cond)
      next unless proc

      begin
        return state_sym if proc.call
      rescue => e
        log(:error, "determine_state execution error for #{state_sym}: #{e}")
      end
    end
    :inactive_unready
  end

  def self.save_config_debounced
    return if @@config_save_pending

    @@config_save_pending = true

    # Cancel existing timer
    GLib::Source.remove(@@config_save_timer) if @@config_save_timer

    # Save after 2 seconds of no changes
    @@config_save_timer = GLib::Timeout.add(2000) do
      File.write(CONFIG_FILE, @@config.to_yaml)
      @@config_save_pending = false
      @@config_save_timer = nil
      false # Don't repeat
    end
  end

  def self.save_window_settings(bar_cfg, window)
    bar_cfg['position'] ||= {}
    x, y = window.position
    return if bar_cfg['position']['x'] == x && bar_cfg['position']['y'] == y
    bar_cfg['position']['x'] = x
    bar_cfg['position']['y'] = y
    bar_cfg['window'] ||= {}
    w, h = window.size
    bar_cfg['window']['width']     = w
    bar_cfg['window']['height']    = h
    bar_cfg['window']['decorated'] = window.decorated?
    save_config_debounced
  end

  def self.save_window_settings_debounced(bar_cfg, window)
    # Cancel previous timer if it exists
    GLib::Source.remove(@@save_timer) if @@save_timer

    # Set new timer - save after 1 second of inactivity
    @@save_timer = GLib::Timeout.add(1000) do
      save_window_settings(bar_cfg, window)
      @@save_timer = nil
      false # Don't repeat
    end
  end

  def self.destroy_window
    @@bar_windows.each(&:destroy)
    @@bar_windows.clear
  end

  def self.request_close
    @close_window = true
  end

  def self.close_requested?
    @close_window
  end

  def self.debug=(value)
    @@debug = value
  end

  def self.debug?
    @@debug || @@config.fetch('debug', false)
  end

  def self.log(level, message)
    return unless debug? || level == :error
    timestamp = Time.now.strftime("%H:%M:%S")
    prefix = case level
             when :error then "ERROR"
             when :warn  then "WARN"
             when :info  then "INFO"
             when :debug then "DEBUG"
             else level.to_s.upcase
             end
    puts "[BarBar #{timestamp}] #{prefix}: #{message}"
  end

  def self.validate_config(config)
    return false unless config.is_a?(Hash)
    return false unless config['bars'].is_a?(Array)

    config['bars'].each do |bar|
      return false unless bar.is_a?(Hash)
      return false unless bar['id']
      return false unless bar['name']

      # Validate position
      if bar['position']
        return false unless bar['position'].is_a?(Hash)
        return false unless bar['position']['x'].is_a?(Numeric) || bar['position']['x'].nil?
        return false unless bar['position']['y'].is_a?(Numeric) || bar['position']['y'].nil?
      end

      # Validate size
      if bar['size']
        return false unless bar['size'].is_a?(Hash)
        %w[cols rows icon_size].each do |key|
          val = bar['size'][key]
          return false unless val.nil? || val.is_a?(Numeric)
        end
      end

      # Validate buttons array
      return false unless bar['buttons'].nil? || bar['buttons'].is_a?(Array)
    end

    true
  rescue => e
    log(:error, "Config validation error: #{e}")
    false
  end

  def self.show_timers?
    @@config.fetch('show_timers', true)
  end

  def self.bar_windows
    @@bar_windows
  end

  def self.press(key)
    cfg = config_for(key)
    return unless cfg
    state = determine_state(cfg)
    cmd   = cfg.dig('states', state.to_s, 'command')
    return if cmd.to_s.strip.empty?

    do_client(cmd)
    puts(">#{cmd}")
  end
end
