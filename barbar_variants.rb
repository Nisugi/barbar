# QUIET
# barbar_variants.rb - Icon variant generation and caching system

module BarBar
  module Variants
    CACHE_VERSION = 1  # Increment to invalidate cache
    CACHE_DIR = File.join(ICON_FOLDER, 'cache', 'variants')
    MANIFEST_FILE = File.join(CACHE_DIR, 'manifest.yaml')
    
    # Variant codes for compact filenames
    VARIANT_CODES = {
      grayscale: 'g',
      green: 'G',
      blue: 'B', 
      red: 'R'
    }
    
    BORDER_COLORS = {
      green: [0, 255, 0],
      blue: [0, 100, 255],
      red: [255, 0, 0]
    }
    
    BORDER_WIDTH = 2
    
    class << self
      def initialize_cache
        require 'fileutils'
        FileUtils.mkdir_p(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
        load_manifest
      end
      
      def load_manifest
        @manifest = if File.exist?(MANIFEST_FILE)
          YAML.load_file(MANIFEST_FILE) || {}
        else
          { 'version' => CACHE_VERSION, 'entries' => {} }
        end
        
        # Clear cache if version mismatch
        if @manifest['version'] != CACHE_VERSION
          clear_cache
          @manifest = { 'version' => CACHE_VERSION, 'entries' => {} }
        end
      end
      
      def save_manifest
        File.write(MANIFEST_FILE, @manifest.to_yaml)
      end
      
      # Main entry point - get an icon variant
      def get_icon(base_map, icon_num, variant_string)
        cache_key = build_cache_key(base_map, icon_num, variant_string)
        cache_path = File.join(CACHE_DIR, "#{cache_key}.png")
        
        # Return cached if exists
        if File.exist?(cache_path)
          begin
            return GdkPixbuf::Pixbuf.new(file: cache_path)
          rescue => e
            BarBar.log(:warn, "Failed to load cached variant #{cache_path}: #{e}")
            File.delete(cache_path) rescue nil
          end
        end
        
        # Generate variant
        generate_variant(base_map, icon_num, variant_string, cache_path)
      end
      
      # Pre-generate all variants needed by current configuration
      def pregenerate_all(button_configs)
        initialize_cache
        count = 0
        errors = []
        
        button_configs.each do |key, cfg|
          next unless cfg['image']
          
          states = cfg['states'] || {}
          states.each do |state_name, state_cfg|
            variant = state_cfg['variant'] || ''
            next if variant.empty?
            
            icon_num = state_cfg['icon'] || 1
            
            begin
              get_icon(cfg['image'], icon_num, variant)
              count += 1
            rescue => e
              errors << "#{key}/#{state_name}: #{e.message}"
            end
          end
        end
        
        save_manifest
        BarBar.log(:info, "Pre-generated #{count} icon variants")
        BarBar.log(:error, "Variant generation errors: #{errors.join(', ')}") unless errors.empty?
        
        { generated: count, errors: errors }
      end
      
      # Clear all cached variants
      def clear_cache
        if Dir.exist?(CACHE_DIR)
          Dir.glob(File.join(CACHE_DIR, '*.png')).each { |f| File.delete(f) rescue nil }
        end
        @manifest = { 'version' => CACHE_VERSION, 'entries' => {} }
        save_manifest
        BarBar.log(:info, "Variant cache cleared")
      end
      
      # Get cache statistics
      def cache_stats
        return { count: 0, size: 0 } unless Dir.exist?(CACHE_DIR)
        
        files = Dir.glob(File.join(CACHE_DIR, '*.png'))
        size = files.sum { |f| File.size(f) rescue 0 }
        
        { count: files.size, size: size, size_mb: (size / 1024.0 / 1024.0).round(2) }
      end
      
      private
      
      def build_cache_key(base_map, icon_num, variant_string)
        # Remove file extension if present
        base_name = File.basename(base_map, '.*')
        
        # Parse variant string (e.g., "_grayscale_green" -> "gG")
        variant_code = parse_variant_code(variant_string)
        
        "#{base_name}_#{icon_num}_#{variant_code}"
      end
      
      def parse_variant_code(variant_string)
        return 'base' if variant_string.nil? || variant_string.empty?
        
        code = ''
        code += VARIANT_CODES[:grayscale] if variant_string.include?('greyscale') || variant_string.include?('grayscale')
        code += VARIANT_CODES[:green] if variant_string.include?('green')
        code += VARIANT_CODES[:blue] if variant_string.include?('blue')
        code += VARIANT_CODES[:red] if variant_string.include?('red')
        
        code.empty? ? 'base' : code
      end
      
      def generate_variant(base_map, icon_num, variant_string, cache_path)
        # Load base sprite map
        sprite_file = File.join(ICON_FOLDER, "#{base_map}.png")
        unless File.exist?(sprite_file)
          raise "Sprite map not found: #{sprite_file}"
        end
        
        sprite = GdkPixbuf::Pixbuf.new(file: sprite_file)
        
        # Calculate icon position in sprite map
        sprite_width = sprite.width
        icons_per_row = sprite_width / ICON_WIDTH
        
        idx = icon_num.to_i - 1
        col = idx % icons_per_row
        row = idx / icons_per_row
        
        # Validate position
        max_rows = sprite.height / ICON_HEIGHT
        if row >= max_rows || col >= icons_per_row
          raise "Icon #{icon_num} out of bounds for sprite map #{base_map}"
        end
        
        # Extract base icon
        icon = sprite.subpixbuf(
          col * ICON_WIDTH,
          row * ICON_HEIGHT,
          ICON_WIDTH,
          ICON_HEIGHT
        )
        
        # Apply variants
        processed = apply_variants(icon, variant_string)
        
        # Save to cache
        FileUtils.mkdir_p(File.dirname(cache_path))
        processed.save(cache_path, 'png')
        
        # Update manifest
        @manifest['entries'][cache_path] = {
          'base_map' => base_map,
          'icon_num' => icon_num,
          'variant' => variant_string,
          'created' => Time.now.to_i
        }
        save_manifest
        
        processed
      end
      
      def apply_variants(pixbuf, variant_string)
        return pixbuf if variant_string.nil? || variant_string.empty?
        
        result = pixbuf
        
        # Apply grayscale first if needed
        if variant_string.include?('greyscale') || variant_string.include?('grayscale')
          result = apply_grayscale(result)
        end
        
        # Then apply border if needed
        if variant_string.include?('green')
          result = apply_border(result, :green)
        elsif variant_string.include?('blue')
          result = apply_border(result, :blue)
        elsif variant_string.include?('red')
          result = apply_border(result, :red)
        end
        
        result
      end
      
      def apply_grayscale(pixbuf)
        # Create new pixbuf for result
        gray = pixbuf.copy
        
        # Use GdkPixbuf's built-in saturation if available
        if gray.respond_to?(:saturate_and_pixelate)
          gray.saturate_and_pixelate(gray, 0.0, false)
          return gray
        end
        
        # Manual grayscale conversion
        # Get pixel data
        pixels = gray.pixels
        rowstride = gray.rowstride
        n_channels = gray.n_channels
        
        gray.height.times do |y|
          gray.width.times do |x|
            offset = y * rowstride + x * n_channels
            
            r = pixels[offset].unpack('C')[0]
            g = pixels[offset + 1].unpack('C')[0]
            b = pixels[offset + 2].unpack('C')[0]
            
            # Standard luminance formula
            gray_value = (0.299 * r + 0.587 * g + 0.114 * b).to_i
            
            pixels[offset] = [gray_value].pack('C')
            pixels[offset + 1] = [gray_value].pack('C')
            pixels[offset + 2] = [gray_value].pack('C')
            # Keep alpha channel (offset + 3) unchanged
          end
        end
        
        gray
      end
      
      def apply_border(pixbuf, color)
        rgb = BORDER_COLORS[color] || BORDER_COLORS[:green]
        
        # Create a copy to modify
        bordered = pixbuf.copy
        
        # Get pixel data
        pixels = bordered.pixels
        rowstride = bordered.rowstride
        n_channels = bordered.n_channels
        width = bordered.width
        height = bordered.height
        
        # Helper to set pixel color
        set_pixel = lambda do |x, y|
          return if x < 0 || y < 0 || x >= width || y >= height
          
          offset = y * rowstride + x * n_channels
          # Check if pixel has alpha > 0 (not transparent)
          if n_channels > 3 && pixels[offset + 3].unpack('C')[0] > 0
            # Only color the border on non-transparent pixels at edges
            check_edge = false
            
            # Check if this pixel is at the edge of non-transparent area
            (-1..1).each do |dy|
              (-1..1).each do |dx|
                next if dx == 0 && dy == 0
                nx, ny = x + dx, y + dy
                
                if nx < 0 || ny < 0 || nx >= width || ny >= height
                  check_edge = true
                  break
                end
                
                noffset = ny * rowstride + nx * n_channels
                if pixels[noffset + 3].unpack('C')[0] == 0
                  check_edge = true
                  break
                end
              end
              break if check_edge
            end
            
            if check_edge
              # Draw border pixel
              pixels[offset] = [rgb[0]].pack('C')
              pixels[offset + 1] = [rgb[1]].pack('C')
              pixels[offset + 2] = [rgb[2]].pack('C')
            end
          end
        end
        
        # Draw border on all edges
        BORDER_WIDTH.times do |i|
          # Top and bottom edges
          width.times do |x|
            set_pixel.call(x, i)                    # Top
            set_pixel.call(x, height - 1 - i)       # Bottom
          end
          
          # Left and right edges
          height.times do |y|
            set_pixel.call(i, y)                    # Left
            set_pixel.call(width - 1 - i, y)        # Right
          end
        end
        
        bordered
      end
    end
  end
end

# Initialize cache on load
BarBar::Variants.initialize_cache if defined?(Gtk)