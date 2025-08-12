# QUIET
# barbar_bar_window.rb - BarWindow class for displaying action bars

module BarBar
  class BarWindow
    def initialize(bar_cfg)
      @cfg         = bar_cfg
      @cols        = bar_cfg.dig('size', 'cols')       || 1
      @rows        = bar_cfg.dig('size', 'rows')       || 1
      @disp_icon_w = bar_cfg.dig('size', 'icon_size')  || ICON_WIDTH
      @spacing     = bar_cfg['spacing']               || 0
      @keys        = bar_cfg['buttons']               || []

      build_window
      build_buttons
      start_timer
    end

    def build_window
      @win = Gtk::Window.new(@cfg['name'] || 'Bar')
      @win.set_app_paintable(true)
      @win.accept_focus = false
      @win.focus_on_map = false
      @win.override_background_color(:normal, Gdk::RGBA.parse("rgba(0,0,0,0)"))
      ws = @cfg['window'] || {}
      default_w = @cols * @disp_icon_w + (@cols - 1) * @spacing
      default_h = @rows * @disp_icon_w + (@rows - 1) * @spacing
      win_w = ws['width'] || default_w
      win_h = ws['height'] || default_h
      @win.set_default_size(win_w, win_h)
      if (p = @cfg['position'])
        @win.move(p['x'], p['y']) if p['x'] && p['y']
      end
      atop = @cfg.dig('window', 'always_on_top')
      @win.decorated = @cfg.dig('window', 'decorated').nil? ? true : @cfg['window']['decorated']
      @win.set_keep_above(atop.nil? ? true : atop)

      @last_click_pos = nil
      menu = Gtk::Menu.new

      config_item = Gtk::MenuItem.new(label: 'Configure BarBar')
      config_item.signal_connect('activate') do
        ConfigWindow.new(BarBar.config, @win, @cfg['id'])
      end
      menu.append(config_item)

      toggle_border = Gtk::MenuItem.new(label: 'Toggle Window Border')
      toggle_border.signal_connect('activate') { toggle_decorations }
      menu.append(toggle_border)

      top_item = Gtk::CheckMenuItem.new(label: 'Always on top')
      top_item.active = (@cfg.dig('window', 'always_on_top').nil? ? true : @cfg['window']['always_on_top'])
      top_item.signal_connect('toggled') do
        @win.set_keep_above(top_item.active?)
        @cfg['window']['always_on_top'] = top_item.active?
        BarBar.save_window_settings(@cfg, @win)
      end
      menu.append(top_item)

      dark_item = Gtk::CheckMenuItem.new(label: 'Dark Mode')
      dark_item.active = BarBar.class_variable_get(:@@config).fetch('dark_mode', false)
      dark_item.signal_connect('toggled') do
        BarBar.class_variable_get(:@@config)['dark_mode'] = dark_item.active?
        File.write(BarBar::CONFIG_FILE, BarBar.class_variable_get(:@@config).to_yaml)
        BarBar.apply_css
      end
      menu.append(dark_item)

      timer_item = Gtk::CheckMenuItem.new(label: 'Show Timers')
      timer_item.active = BarBar.show_timers?
      timer_item.signal_connect('toggled') do
        BarBar.class_variable_get(:@@config)['show_timers'] = timer_item.active?
        File.write(BarBar::CONFIG_FILE, BarBar.class_variable_get(:@@config).to_yaml)
        BarBar.bar_windows.each do |bw|
          bw.instance_variable_get(:@buttons).each_value do |info|
            info[:btn].queue_draw
          end
        end
      end
      menu.append(timer_item)

      menu.show_all
      @win.add_events(Gdk::EventMask::BUTTON_PRESS_MASK)
      @win.signal_connect('button-press-event') do |_, event|
        if event.button == 3
          @last_click_pos = [event.x_root.to_i, event.y_root.to_i]
          menu.popup_at_pointer(event)
          true
        else
          false
        end
      end

      @win.signal_connect('delete-event') do |_, _|
        BarBar.save_window_settings(@cfg, @win)
        BarBar.request_close
        true
      end
      @win.signal_connect('configure-event') do |w, _event|
        BarBar.save_window_settings_debounced(@cfg, w)
        false
      end
    end

    def build_buttons
      scroll = Gtk::ScrolledWindow.new
      scroll.set_policy(:automatic, :automatic)
      @win.add(scroll)

      grid = Gtk::Grid.new
      grid.row_spacing    = @spacing
      grid.column_spacing = @spacing
      scroll.add(grid)

      @buttons = {}

      # Get timer font size for this bar (falls back to global or default)
      timer_size = @cfg.fetch('timer_font_size', nil)

      @keys.each_with_index do |key, idx|
        next unless (btn_cfg = BarBar.config_for(key))

        # Create BarButton instance
        button = BarBar::BarButton.new(key, btn_cfg, @disp_icon_w, @disp_icon_w, @spacing, timer_size)
        @buttons[key] = button

        # Add to grid
        c = idx % @cols
        r = idx / @cols
        grid.attach(button.widget, c, r, 1, 1)
      end

      @win.show_all
    end

    def start_timer
      @next_update_times = {}
      @timer = GLib::Timeout.add(100) { smart_update_buttons; true }
    end

    def format_time(sec)
      case sec
      when 0...100
        "#{sec}s"
      when 100...5940
        # round to nearest minute
        minutes = (sec / 60.0).round
        "#{minutes}m"
      else
        # round to nearest hour
        hours = (sec / 3600.0).round
        "#{hours}h"
      end
    end

    def smart_update_buttons
  return false if @win.nil? || (@win.respond_to?(:destroyed?) && @win.destroyed?)
      now = Time.now.to_f
      updates_needed = false

      visible_area = ( @win && (!@win.respond_to?(:destroyed?) || !@win.destroyed?) && @win.visible? ) ? @win.allocation : nil

      @buttons.each do |key, button|
        next if button.destroyed?
        # Skip if button is scrolled out of view
        if visible_area && button.widget.allocation
          btn_alloc = button.widget.allocation
          next unless btn_alloc.intersect(visible_area)
        end
        next_update = @next_update_times[key] || 0

        if now >= next_update
          # Update the button and get its timer value
          result = button.update
          updates_needed = true if result[:changed]

          # Calculate next update based on timer value
          @next_update_times[key] = now + calculate_update_interval(result[:timer])
        end
      end
      # Force a single redraw after all updates
      @win.queue_draw if updates_needed
    end

    def calculate_update_interval(timer_seconds)
      return 0.25 unless timer_seconds && timer_seconds > 0

      case timer_seconds
      when 0..15
        1.0     # Update every second for last 10 seconds
      when 16..3599
        5.0     # Update every 5 seconds for under an hour
      else
        300.0   # Update every 5 minutes for hours
      end
    end

    def destroy
      # CRITICAL: Remove timer first to prevent callbacks on destroyed widgets
      GLib::Source.remove(@timer) if @timer
      @timer = nil

      # Then destroy buttons
      @buttons.each_value(&:destroy)
      @buttons.clear

      # Finally destroy window
      @win.destroy
  @win = nil
    end

    def toggle_decorations
      BarBar.save_window_settings(@cfg, @win)
      @cfg['window']['decorated'] = !@win.decorated?
      File.write(BarBar::CONFIG_FILE, BarBar.class_variable_get(:@@config).to_yaml)

      @win.destroy
      build_window
      build_buttons
      start_timer
    end
  end
end
