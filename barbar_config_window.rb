# QUIET
# barbar_config_window.rb - ConfigWindow class for BarBar configuration UI

class ConfigWindow < Gtk::Window
  def initialize(config, parent_window = nil, selected_bar_id = nil)
    @config = config
    @parent_window = parent_window
    @bar_tabs = {}
    @controls = {}

    super()
    set_title('BarBar Configurator')
    set_default_size(600, 400)
    set_keep_above(true)
    if parent_window
      set_transient_for(parent_window)
      set_position(Gtk::WindowPosition::CENTER_ON_PARENT)
    end

    # Notebook to hold one tab per bar
    notebook = Gtk::Notebook.new

    @bar_tabs = {} # bar_id => page widget

    icon_page, icon_ctrlls = build_button_manager_tab
    notebook.append_page(icon_page, Gtk::Label.new('Manage Buttons'))

    browse_page = build_browse_icons_tab
    notebook.append_page(browse_page, Gtk::Label.new('Browse Icons'))
    @controls[:icon_manager] = icon_ctrlls

    # For each bar in config, create a tab
    @config['bars'].each do |bar_cfg|
      page, ctrls = build_bar_tab(bar_cfg)
      notebook.append_page(page, Gtk::Label.new(bar_cfg['name']))
      @bar_tabs[bar_cfg['id']] = page
      @controls[bar_cfg['id']] = ctrls
    end

    # "Add Bar" button below
    add_bar_btn = Gtk::Button.new(label: 'Add Bar')
    add_bar_btn.signal_connect('clicked') { add_new_bar_tab(notebook) }

    save_all   = Gtk::Button.new(label: 'Save All')
    cancel_btn = Gtk::Button.new(label: 'Cancel')

    ctrl_box = Gtk::Box.new(:horizontal, 6)
    ctrl_box.homogeneous = true
    [add_bar_btn, save_all, cancel_btn].each do |btn|
      ctrl_box.pack_start(btn, expand: true, fill: true, padding: 4)
    end

    # pack notebook + button in a VBox
    vbox = Gtk::Box.new(:vertical, 6)
    vbox.pack_start(notebook, expand: true, fill: true, padding: 0)
    vbox.pack_start(add_bar_btn, expand: false, fill: false, padding: 4)
    vbox.pack_end(ctrl_box, expand: false, fill: false, padding: 4)
    self.child = vbox

    # on save: pull all fields back into bar_cfg + write YAML + reload
    save_all.signal_connect('clicked') do
      @config['bars'].each do |bar_cfg|
        ctrls = @controls[bar_cfg['id']]
        bar_cfg['name']      = ctrls[:name_entry].text
        bar_cfg['enabled']   = ctrls[:enabled_cb].active?
        bar_cfg['position']  = { 'x' => ctrls[:x_spin].value.to_i, 'y' => ctrls[:y_spin].value.to_i }
        bar_cfg['size']      = {
          'cols'      => ctrls[:cols_spin].value.to_i,
          'rows'      => ctrls[:rows_spin].value.to_i,
          'icon_size' => ctrls[:isz_spin].value.to_i
        }
        bar_cfg['spacing'] = ctrls[:spn_spin].value.to_i
        bar_cfg['timer_font_size'] = ctrls[:timer_spin].value.to_i if ctrls[:timer_spin]
        sel = []
        store = ctrls[:store]
        store.each do |_, _, iter|
          key, included = iter[0], iter[1]
          sel << key if included
        end
        bar_cfg['buttons'] = sel
      end

      # Pre-generate all icon variants
      button_configs = BarBar.load_button_configs
      result = BarBar::Variants.pregenerate_all(button_configs)
      if result[:errors].any?
        # Show warning dialog but continue
        dialog = Gtk::MessageDialog.new(
          parent: self,
          flags: :destroy_with_parent,
          type: :warning,
          buttons_type: :ok,
          message: "Some icon variants could not be generated:\n#{result[:errors].take(5).join("\n")}"
        )
        dialog.run
        dialog.destroy
      end

      # persist & reload all bars
      File.write(BarBar::CONFIG_FILE, @config.to_yaml)
      BarBar.initialize
      destroy
    end

    cancel_btn.signal_connect('clicked') { destroy }

    show_all

    if selected_bar_id && @bar_tabs.key?(selected_bar_id)
      page_widget = @bar_tabs[selected_bar_id]
      idx = notebook.page_num(page_widget)
      # only set if it's a valid index
      notebook.current_page = idx if idx && idx >= 0
    end
  end

  def set_active_by_text(combo, text)
    combo.model.each do |_, path, iter|
      if iter[0] == text
        combo.active = path.indices.first
        break
      end
    end
  end

  def build_button_manager_tab
    # 1) grab all the existing button defs
    defs     = BarBar.load_button_configs
    all_keys = defs.keys.sort

    # 2) create main grid
    grid = Gtk::Grid.new
    grid.column_spacing = 8
    grid.row_spacing    = 6
    grid.margin = 12

    # 3) Row 0: key selector
    key_sel = Gtk::ComboBoxText.new
    key_sel.append_text('<< New >>')
    all_keys.each { |k| key_sel.append_text(k) }
    key_sel.active = 0
    grid.attach(Gtk::Label.new('Button Key:'), 0, 0, 1, 1)
    grid.attach(key_sel, 1, 0, 3, 1)

    # 4) Rows 1–6: basic fields
    name_e   = Gtk::Entry.new
    cat_e    = Gtk::Entry.new
    img_combo = Gtk::ComboBoxText.new
    [name_e, cat_e, img_combo].each { |w| w.hexpand = true }

    grid.attach(Gtk::Label.new('Name:'),            0, 1, 1, 1); grid.attach(name_e, 1, 1, 3, 1)
    grid.attach(Gtk::Label.new('Category:'), 0, 2, 1, 1); grid.attach(cat_e, 1, 2, 3, 1)
    grid.attach(Gtk::Label.new('Image Base:'), 0, 3, 1, 1); grid.attach(img_combo, 1, 3, 3, 1)

    # populate image choices
    Dir.glob(File.join(BarBar::ICON_FOLDER, '*.png')).each do |f|
      base = File.basename(f, '.png')
      img_combo.append_text(base)
    end

    # 5) Rows 4–10: state-frames in a sub-notebook
    state_keys = %w[inactive_ready inactive_unready active_ready active_unready]
    total_icons = BarBar::ICONS_PER_ROW * BarBar::ICONS_PER_ROW
    state_nb = Gtk::Notebook.new
    state_widgets = {}

    state_keys.each do |st_key|
      fg = Gtk::Grid.new
      fg.row_spacing    = 6
      fg.column_spacing = 6
      fg.margin_bottom = 6

      preview = Gtk::Image.new
      preview.set_size_request(64, 64)
      fg.attach(preview, 2, 0, 4, 2)

      vcombo = Gtk::ComboBoxText.new
      ['', 'grayscale', 'green', 'blue', 'red', 
       'grayscale_green', 'grayscale_blue', 'grayscale_red'].each { |v| 
        vcombo.append_text(v) 
      }
      vcombo.active = 0
      fg.attach(Gtk::Label.new('Variant:'),   0, 0, 1, 1)
      fg.attach(vcombo,                       1, 0, 1, 1)

      ispin = Gtk::SpinButton.new(1, total_icons, 1)
      fg.attach(Gtk::Label.new('Icon #:'),    0, 1, 1, 1)
      fg.attach(ispin,                        1, 1, 1, 1)

      cmd_e = Gtk::Entry.new
      fg.attach(Gtk::Label.new('Command:'),   0, 2, 1, 1)
      fg.attach(cmd_e,                        1, 2, 54, 1)

      gc_e = Gtk::Entry.new
      fg.attach(Gtk::Label.new('Group Cmd:'), 0, 3, 1, 1)
      fg.attach(gc_e,                         1, 3, 54, 1)

      cond_e = Gtk::Entry.new
      fg.attach(Gtk::Label.new('Condition:'), 0, 4, 1, 1)
      fg.attach(cond_e,                       1, 4, 54, 1)

      timer_e = Gtk::Entry.new
      fg.attach(Gtk::Label.new('Timer:'),     0, 5, 1, 1)
      fg.attach(timer_e,                      1, 5, 54, 1)

      tip_e = Gtk::Entry.new
      fg.attach(Gtk::Label.new('Tooltip:'),   0, 6, 1, 1)
      fg.attach(tip_e,                        1, 6, 54, 1)

      frame = Gtk::Frame.new(st_key)
      frame.add(fg)
      state_nb.append_page(frame, Gtk::Label.new(st_key))

      state_widgets[st_key] = {
        variant: vcombo,
        icon: ispin,
        command: cmd_e,
        group_command: gc_e,
        condition: cond_e,
        timer: timer_e,
        tooltip: tip_e,
        preview: preview
      }

      updater = -> {
        base    = img_combo.active_text
        variant_str = vcombo.active_text || ''
        num     = ispin.value_as_int
        begin
          # Use the variant system to get the icon
          icon = BarBar::Variants.get_icon(base, num, variant_str)
          thumb = icon.scale_simple(64, 64, GdkPixbuf::InterpType::BILINEAR)
          preview.set_from_pixbuf(thumb)
        rescue => e
          BarBar.log(:debug, "Preview error: #{e}")
          preview.clear
        end
      }

      img_combo.signal_connect('changed') { updater.call }
      vcombo.signal_connect('changed') { updater.call }
      ispin.signal_connect('value-changed') { updater.call }
    end

    grid.attach(state_nb, 0, 4, 4, 7)

    save_btn = Gtk::Button.new(label: 'Save Button Definition')
    grid.attach(save_btn, 0, 11, 4, 1)

    load_def = lambda do |selected_key|
      data = defs[selected_key] || {}
      name_e.text  = data['name'].to_s
      cat_e.text   = Array(data['category']).join(', ')
      set_active_by_text(img_combo, data['image'].to_s)
      state_widgets.each do |st, w|
        sd = data.dig('states', st.to_s) || {}
        w[:condition].text = sd['condition'].to_s
        set_active_by_text(w[:variant], sd['variant'].to_s)
        w[:icon].value         = sd['icon'].to_i
        w[:tooltip].text       = sd['tooltip'].to_s
        w[:timer].text         = sd['timer'].to_s
        w[:command].text       = sd['command'].to_s
        w[:group_command].text = sd['group_command'].to_s
      end
    end

    key_sel.signal_connect('changed') { load_def.call(key_sel.active_text) }
    load_def.call(key_sel.active_text)

    save_btn.signal_connect('clicked') do
      key = key_sel.active_text
      if key == '<< New >>'
        key = name_e.text.strip.downcase.gsub(/\s+/, '_')
        defs[key] = {}
        key_sel.append_text(key)
      end

      # build up the hash
      states_hash = state_widgets.each_with_object({}) do |(st, w), h|
        h[st.to_s] = {
          'variant'       => w[:variant].active_text,
          'icon'          => w[:icon].value.to_i,
          'command'       => w[:command].text,
          'group_command' => w[:group_command].text,
          'condition'     => w[:condition].text,
          'timer'         => w[:timer].text,
          'tooltip'       => w[:tooltip].text
        }
      end

      defs[key] = {
        'name'     => name_e.text,
        'category' => cat_e.text.split(',').map(&:strip),
        'image'    => img_combo.active_text,
        'states'   => states_hash
      }

      BarBar.instance_variable_set(:@button_configs, defs)
      BarBar.save_button_configs
      set_active_by_text(key_sel, key)
    end

    # return the tab page + controls if you need them
    [grid, { selector: key_sel }]
  end

  def build_browse_icons_tab
    # Only show base sprite maps (no variants)
    images = Dir.glob(File.join(BarBar::ICON_FOLDER, '*.png'))
                .map { |f| File.basename(f, '.png') }
                .reject { |f| f.include?('_green') || f.include?('_blue') || 
                             f.include?('_red') || f.include?('_greyscale') || 
                             f.include?('_grayscale') }
                .uniq
                .sort

    # layout
    vbox = Gtk::Box.new(:vertical, 6)
    vbox.margin = 12

    # row selector & image dropdown
    ctrl = Gtk::Box.new(:horizontal, 6)
    img_combo = Gtk::ComboBoxText.new
    images.each { |img| img_combo.append_text(img) }
    img_combo.active = 0
    ctrl.pack_start(Gtk::Label.new('Sprite Map:'), expand: false, fill: false, padding: 0)
    ctrl.pack_start(img_combo, expand: false, fill: false, padding: 0)

    max_rows = BarBar::ICONS_PER_ROW
    row_spin = Gtk::SpinButton.new(1, max_rows, 1)
    ctrl.pack_start(Gtk::Label.new('Row:'), expand: false, fill: false, padding: 0)
    ctrl.pack_start(row_spin, expand: false, fill: false, padding: 0)

    range_lbl = Gtk::Label.new('')
    ctrl.pack_start(range_lbl, expand: true, fill: true, padding: 0)

    vbox.pack_start(ctrl, expand: false, fill: false, padding: 0)

    # scrollable grid
    scroll = Gtk::ScrolledWindow.new
    scroll.set_policy(:automatic, :automatic)
    grid = Gtk::Grid.new
    grid.row_spacing    = 4
    grid.column_spacing = 4
    scroll.add(grid)
    vbox.pack_start(scroll, expand: true, fill: true, padding: 0)

    # helper to render one row of icons
    render = lambda do
      grid.each { |c| grid.remove(c) }
      base = img_combo.active_text
      return unless base
      file = File.join(BarBar::ICON_FOLDER, "#{base}.png")
      unless File.exist?(file)
        range_lbl.text = "File not found: #{base}.png"
        return
      end
      begin
        pix = GdkPixbuf::Pixbuf.new(file: file)
        icons_per_row = pix.width / BarBar::ICON_WIDTH
        max_rows = pix.height / BarBar::ICON_HEIGHT
        row  = row_spin.value_as_int - 1
        start = row * icons_per_row

        icons_per_row.times do |i|
          sub = pix.subpixbuf(i * BarBar::ICON_WIDTH, row * BarBar::ICON_HEIGHT,
                              BarBar::ICON_WIDTH, BarBar::ICON_HEIGHT)
          thumb = sub.scale_simple(75, 75, GdkPixbuf::InterpType::BILINEAR)
          eb = Gtk::EventBox.new.add(Gtk::Image.new(pixbuf: thumb))
          grid.attach(eb, i % 8, i / 8, 1, 1)
        end

        range_lbl.text = "Icons #{start + 1}–#{start + BarBar::ICONS_PER_ROW}"
        grid.show_all
      rescue => e
        range_lbl.text = "Error loading #{base}.png: #{e.message}"
      end
    end

    img_combo.signal_connect('changed') { render.call }
    row_spin.signal_connect('value-changed') { render.call }
    render.call

    vbox
  end

  # Build one tab's content for editing a single bar
  def build_bar_tab(bar_cfg)
    grid = Gtk::Grid.new
    grid.column_spacing = 8
    grid.row_spacing = 6
    grid.set_margin_top(12)
    grid.set_margin_bottom(12)
    grid.set_margin_start(12)
    grid.set_margin_end(12)

    # Name
    grid.attach(Gtk::Label.new('Name:'), 0, 0, 1, 1)
    name_entry = Gtk::Entry.new
    name_entry.text = bar_cfg['name']
    grid.attach(name_entry, 1, 0, 2, 1)

    # Enabled
    enabled_cb = Gtk::CheckButton.new
    enabled_cb.label = 'Enabled'
    enabled_cb.active = bar_cfg['enabled']
    grid.attach(enabled_cb, 0, 1, 1, 1)

    # Position
    grid.attach(Gtk::Label.new('X:'), 0, 2, 1, 1)
    x_spin = Gtk::SpinButton.new(0, 5000, 1)
    x_spin.value = bar_cfg.dig('position', 'x') || 100
    grid.attach(x_spin, 1, 2, 1, 1)

    grid.attach(Gtk::Label.new('Y:'), 2, 2, 1, 1)
    y_spin = Gtk::SpinButton.new(0, 5000, 1)
    y_spin.value = bar_cfg.dig('position', 'y') || 100
    grid.attach(y_spin, 3, 2, 1, 1)

    # Size: cols, rows, icon_size, spacing
    grid.attach(Gtk::Label.new('Cols:'), 0, 3, 1, 1)
    cols_spin = Gtk::SpinButton.new(1, 20, 1)
    cols_spin.value = bar_cfg.dig('size', 'cols') || 10
    grid.attach(cols_spin, 1, 3, 1, 1)

    grid.attach(Gtk::Label.new('Rows:'), 2, 3, 1, 1)
    rows_spin = Gtk::SpinButton.new(1, 10, 1)
    rows_spin.value = bar_cfg.dig('size', 'rows') || 1
    grid.attach(rows_spin, 3, 3, 1, 1)

    grid.attach(Gtk::Label.new('Icon Size:'), 0, 4, 1, 1)
    isz_spin = Gtk::SpinButton.new(16, 128, 1)
    isz_spin.value = bar_cfg.dig('size', 'icon_size') || 64
    grid.attach(isz_spin, 1, 4, 1, 1)

    grid.attach(Gtk::Label.new('Spacing:'), 2, 4, 1, 1)
    spn_spin = Gtk::SpinButton.new(0, 20, 1)
    spn_spin.value = bar_cfg['spacing'] || 2
    grid.attach(spn_spin, 3, 4, 1, 1)

    # Timer font size
    grid.attach(Gtk::Label.new('Timer Font:'), 0, 5, 1, 1)
    timer_spin = Gtk::SpinButton.new(8, 48, 1)
    timer_spin.value = bar_cfg['timer_font_size'] || bar_cfg.dig('size', 'icon_size').to_i / 2
    grid.attach(timer_spin, 1, 5, 1, 1)

    # Category filter
    defs       = BarBar.load_button_configs
    categories = defs.values.flat_map { |cfg| Array(cfg['category']) }.compact.uniq.sort

    combo = Gtk::ComboBoxText.new
    combo.append_text('All')
    categories.each { |cat| combo.append_text(cat) }
    combo.active = 0

    grid.attach(Gtk::Label.new('Category:'), 0, 6, 1, 1)
    grid.attach(combo, 1, 6, 3, 1)

    # Button Picker
    all_keys = defs.keys.sort
    store = Gtk::ListStore.new(String, FalseClass)
    all_keys.each do |k|
      iter = store.append
      iter[0] = k
      iter[1] = bar_cfg['buttons'].include?(k)
    end

    combo.signal_connect('changed') do |c|
      selected = c.active_text
      store.clear
      all_keys.each do |k|
        cfg = defs[k]
        next if selected != 'All' && !Array(cfg['category']).include?(selected)
        iter = store.append
        iter[0], iter[1] = k, bar_cfg['buttons'].include?(k)
      end
    end

    tv = Gtk::TreeView.new(store)
    renderer_text = Gtk::CellRendererText.new
    col_text = Gtk::TreeViewColumn.new('Button', renderer_text, text: 0)
    tv.append_column(col_text)
    renderer_toggle = Gtk::CellRendererToggle.new
    toggle_col = Gtk::TreeViewColumn.new('Include', renderer_toggle, active: 1)
    renderer_toggle.signal_connect('toggled') do |_, path|
      iter = store.get_iter(path)
      iter[1] = !iter[1]
    end
    tv.append_column(toggle_col)
    sel    = tv.selection
    up_btn = Gtk::Button.new(label: '↑')
    dn_btn = Gtk::Button.new(label: '↓')

    up_btn.signal_connect('clicked') do
      if (iter = sel.selected)
        path = store.get_path(iter)
        idx  = path.indices[0]
        if idx > 0
          above = store.iter_nth_child(nil, idx - 1)
          swap_rows(store, iter, above)
          sel.select_path(store.get_path(above))
        end
      end
    end

    dn_btn.signal_connect('clicked') do
      if (iter = sel.selected)
        path = store.get_path(iter)
        idx = path.indices[0]
        total = store.iter_n_children(nil)
        if idx < total - 1
          below = store.iter_nth_child(nil, idx + 1)
          swap_rows(store, iter, below)
          sel.select_path(store.get_path(below))
        end
      end
    end

    scroll = Gtk::ScrolledWindow.new
    scroll.set_policy(:automatic, :automatic)
    scroll.set_min_content_height(200)
    scroll.set_vexpand(true)
    scroll.add(tv)

    hbox = Gtk::Box.new(:horizontal, 4)
    hbox.pack_start(scroll, expand: true, fill: true, padding: 0)

    btn_box = Gtk::Box.new(:vertical, 2)
    btn_box.pack_start(up_btn, expand: false, fill: false, padding: 2)
    btn_box.pack_start(dn_btn, expand: false, fill: false, padding: 2)
    hbox.pack_start(btn_box, expand: false, fill: false, padding: 0)

    grid.attach(hbox, 0, 7, 4, 4)

    ctrls = {
      name_entry: name_entry,
      enabled_cb: enabled_cb,
      x_spin: x_spin,
      y_spin: y_spin,
      cols_spin: cols_spin,
      rows_spin: rows_spin,
      isz_spin: isz_spin,
      spn_spin: spn_spin,
      timer_spin: timer_spin,
      store: store
    }

    [grid, ctrls]
  end

  # Add a brand-new empty bar
  def add_new_bar_tab(notebook)
    new_id = "bar#{Time.now.to_i}"
    pos = if @parent_window
            x, y = @parent_window.position
            { 'x' => x, 'y' => y }
          else
            { 'x' => 100, 'y' => 100 }
          end

    new_bar = {
      'id'       => new_id,
      'name'     => 'New Bar',
      'enabled'  => true,
      'position' => pos,
      'size'     => { 'cols' => 10, 'rows' => 1, 'icon_size' => 64 },
      'spacing'  => 2,
      'buttons'  => []
    }
    @config['bars'] << new_bar
    page, ctrls = build_bar_tab(new_bar)
    @bar_tabs[new_id] = page
    @controls[new_id] = ctrls
    notebook.append_page(page, Gtk::Label.new(new_bar['name']))
    show_all
  end

  private

  def swap_rows(store, iter1, iter2)
    (0...store.n_columns).each do |col|
      v1 = store.get_value(iter1, col)
      v2 = store.get_value(iter2, col)
      store.set_value(iter1, col, v2)
      store.set_value(iter2, col, v1)
    end
  end
end
