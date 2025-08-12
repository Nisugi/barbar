# QUIET
# barbar_constants.rb - Constants and configuration paths for BarBar

module BarBar
  ICON_FOLDER   ||= File.join(DATA_DIR, 'icons')
  CONFIG_FILE   ||= File.join(ICON_FOLDER, "#{Char.name}_bars.yaml")
  BUTTON_CFG    ||= File.join(ICON_FOLDER, "#{Char.name}_buttons.yaml")

  ICON_WIDTH    ||= 64
  ICON_HEIGHT   ||= 64

  TIMER_UPDATE_INTERVAL ||= 250 # ms
  SAVE_DEBOUNCE_DELAY ||= 1000 # ms
  DEFAULT_ICON_SIZE ||= 64
  MAX_PREVIEW_SIZE ||= 75

  MAX_CACHE_SIZE ||= 200
  MAX_COMPILED_EXPR_CACHE ||= 100

  MAX_DATA_POOL_SIZE ||= 50
  MAX_BORDER_WIDTH ||= 5
  MIN_BORDER_WIDTH ||= 1
  DEFAULT_BORDER_WIDTH ||= 2
end
