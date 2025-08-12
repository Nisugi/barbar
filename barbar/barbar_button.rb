# QUIET
# barbar_button.rb - BarButton class for individual button management

module BarBar
  class BarButton
    attr_reader :key, :cfg, :widget, :image_widget, :timer_label
    attr_accessor :last_state, :last_timer_value

    @@time_format_cache = {}

    def initialize(key, cfg, icon_width, icon_height, spacing, timer_size = nil)
      @key = key
      @cfg = cfg
      @icon_width = icon_width
      @icon_height = icon_height
      @spacing = spacing
      @timer_size = timer_size
      @last_state = nil
      @last_timer_value = nil
      @cached_state = nil
      @cache_time = 0

      build_widget
    end

    def build_widget
      # Create the button image
      @image_widget = BarBar.create_icon(@cfg, :inactive_ready, @icon_width, @icon_height)

      # Create overlay for timer
      overlay = Gtk::Overlay.new
      overlay.add(@image_widget)

      # Only create timer label if this button has timer expressions
      if button_has_timer?
        @timer_label = Gtk::Label.new("")
        @timer_label.set_halign(:center)
        @timer_label.set_valign(:end)
        @timer_label.style_context.add_class("skillbar-timer")
        # Apply custom timer size if specified for this bar
        if @timer_size
          css = "label { font-size: #{@timer_size}px; }"
          provider = Gtk::CssProvider.new
          provider.load(data: css)
          @timer_label.style_context.add_provider(provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
        end
        @timer_label.hide
        # Make label completely transparent to mouse events
        if @timer_label.respond_to?(:set_has_window)
          @timer_label.set_has_window(false)
        end
        @timer_label.sensitive = false # Won't receive any events
        overlay.add_overlay(@timer_label)
        overlay.set_overlay_pass_through(@timer_label, true) if overlay.respond_to?(:set_overlay_pass_through)
      else
        @timer_label = nil
      end

      # Create the button
      @widget = Gtk::Button.new
      @widget.set_relief(:none)
      @widget.add(overlay)
      update_tooltip(current_state)
      @widget.can_focus = false

      # Connect click handler
      @widget.signal_connect('clicked') { on_click }
    end

    def button_has_timer?
      states = @cfg['states'] || {}
      states.any? { |_, state_cfg| state_cfg['timer'] && !state_cfg['timer'].empty? }
    end

    def update_tooltip(state)
      state_cfg = @cfg.dig('states', state.to_s) || {}
      tooltip = state_cfg['tooltip'] || @cfg['name']
      @widget.tooltip_text = tooltip if @widget.tooltip_text != tooltip
    end

    def on_click
      state = current_state
      state_cfg = @cfg.dig('states', state.to_s) || {}

      if (cmd = state_cfg['command']) && !cmd.empty?
        # Check if it's a simple command or needs evaluation
        if cmd.include?('#{') || cmd.include?('<%')
          # Needs interpolation - compile and execute
          proc = BarBar.compile_expression("\"#{cmd}\"")
          actual_cmd = proc.call if proc
        else
          # Simple string command
          actual_cmd = cmd
        end

        if actual_cmd
          do_client(actual_cmd)
          puts("> #{actual_cmd}")
        end
        BarBar.log(:debug, "Button #{@key} clicked, executing: #{cmd}")
      end

      # Focus game window after click
      Frontend.refocus_callback.call if defined?(Frontend) && !Frontend.pid.nil?
    end

    def current_state(force_refresh = false)
      # Cache state for 100ms to reduce evaluations
      now = Time.now.to_f

      if !force_refresh && @cached_state && (now - @cache_time < 0.1)
        return @cached_state
      end

      state = BarBar.determine_state(@cfg)
      @cached_state = state
      @cache_time = now
      state
    end

    def update
      state = current_state
      state_changed = false

      if state != @last_state
        new_image = BarBar.create_icon(@cfg, state, @icon_width, @icon_height)
        @image_widget.set_from_pixbuf(new_image.pixbuf)
        update_tooltip(state)
        @last_state = state
        state_changed = true
      end

      timer_value = update_timer(state)
      { timer: timer_value, changed: state_changed || timer_value != @last_timer_value }
    end

    def update_timer(state)
      return nil unless BarBar.show_timers?
      return nil if !@timer_label || @timer_label.destroyed?

      state_cfg = @cfg.dig('states', state.to_s) || {}
      timer_value = nil

      if (expr = state_cfg['timer'])
        proc = BarBar.compile_expression(expr)
        if proc
          timer_value = begin
            raw = proc.call
            Array(raw).first.to_i
          rescue => e
            BarBar.log(:error, "Timer execution error for #{@key}: #{e}")
            0
          end
        end
      end

      # Only update if timer value changed
      if timer_value != @last_timer_value
        @last_timer_value = timer_value
        return timer_value if @timer_label.destroyed?

        if timer_value && timer_value > 0
          @timer_label.text = format_time(timer_value)
          @timer_label.visible = true if !@timer_label.visible?
        else
          @timer_label.text = ""
          @timer_label.visible = false if @timer_label.visible?
        end
      end
      timer_value
    end

    def format_time(seconds)
      return @@time_format_cache[seconds] if @@time_format_cache[seconds]

      result =
        case seconds
        when 0...100
          "#{seconds}s"
        when 100...5940
          "#{(seconds / 60.0).round}m"
        else
          "#{(seconds / 3600.0).round}h"
        end
      @@time_format_cache[seconds] = result if seconds % 5 == 0 || seconds < 20
      result
    end

    def destroy
      # Mark as destroyed first
      @destroyed = true

      # Clean up widget references
      @timer_label = nil
      @image_widget = nil

      # Destroy the main widget
      @widget.destroy if @widget
      @widget = nil

      # Clear cached state
      @cached_state = nil
    end

    def destroyed?
      @destroyed || (@widget && @widget.destroyed?)
    end
  end
end
