=begin
  ;barbar.lic   Graphical Action Bars

  right click on window to configure
  sprite maps goes into Lich5/data/icons
  sprite maps should be 2048 x 2048 pixels
    with icons being 64 x 64 pixels, no padding between icons

  todo:
    investigate assigning button presses to trigger vs clicks
    button to reload button info into memory - creating a new button requires relaunching config to populate it.

  ;eq BarBar.press(key)  - triggers button

=end

require 'gtk3'
require 'yaml'

# Load all the modular components
Script.run('barbar_constants')
Script.run('barbar_helpers')
Script.run('barbar_config_window')
Script.run('barbar_button')
Script.run('barbar_bar_window')

module BarBar
  # Top-level kickoff: load bars.yaml (or default), spin up windows
  def self.initialize
    Gtk.queue do
      destroy_window
      raw = File.exist?(CONFIG_FILE) ? YAML.load_file(CONFIG_FILE) : nil
      if validate_config(raw)
        @@config = raw
        log(:info, "Config loaded successfully")
      else
        log(:warn, "Invalid config detected, using defaults")
        @@config = {
          'bars' => [
            {
              'id' => 'default', 'name' => 'Main Bar', 'enabled' => true,
              'position' => { 'x' => 100, 'y' => 100 },
              'size' => { 'cols' => 10, 'rows' => 1, 'icon_size' => 64 },
              'spacing' => 2, 'buttons' => []
            }
          ]
        }
      end

      apply_css
      @@show_timers = @@config.fetch('show_timers', true)

      # build a window per enabled bar
      @@config['bars'].each do |bar|
        next unless bar['enabled']
        @@bar_windows << BarWindow.new(bar)
      end
    end
  end
end

# finally launch it
BarBar.initialize
before_dying do
  Gtk.queue do
    # Get windows before destroying them
    windows = BarBar.class_variable_get(:@@bar_windows)

    # Destroy each window properly
    windows.each do |window|
      window.destroy rescue nil
    end

    # Clear the array
    windows.clear

    # Clear caches
    BarBar.clear_pixbuf_cache rescue nil
  end
end

until BarBar.close_requested?
  sleep(1)
end
Gtk.queue do
  BarBar.class_variable_get(:@@bar_windows).each(&:destroy) rescue nil
end
exit
