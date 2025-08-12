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
      
      def make_pixbuf_from_pixels(src_pixbuf, pixels_str)
        bin = pixels_str.dup
        bin.force_encoding('ASCII-8BIT')
        @_data_pool << bin
        GdkPixbuf::Pixbuf.new(
          data: bin,
          colorspace: src_pixbuf.colorspace,
          has_alpha: src_pixbuf.has_alpha?,
          bits_per_sample: src_pixbuf.bits_per_sample,
          width: src_pixbuf.width,
          height: src_pixbuf.height,
          rowstride: src_pixbuf.rowstride
        )
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

      def byte_get(buf, idx)
        buf.is_a?(String) ? buf.getbyte(idx) : buf[idx]
      end

      def byte_set(buf, idx, val)
        if buf.is_a?(String)
          buf.setbyte(idx, val)
        else
          buf[idx] = val
        end
      end

      def copy_span(dst, dst_off, src, src_off, len)
        i = 0
        while i < len
          byte_set(dst, dst_off + i, byte_get(src, src_off + i))
          i += 1
        end
      end
      
      @_data_pool ||= []

      def to_tight_bytes(src)
        n = src.n_channels
        w = src.width
        h = src.height
        tight = w * n
        s_stride = src.rowstride
        s = src.pixels

        out = "\x00" * (tight * h)
        h.times do |y|
          copy_span(out, y * tight, s, y * s_stride, tight)
        end
        [out, w, h, n, src.colorspace, src.has_alpha?, src.bits_per_sample]
      end

      def ensure_tight(src)
        n = src.n_channels
        w = src.width
        h = src.height
        tight = w * n

        # If already tight, nothing to do
        return src if src.rowstride == tight

        dst = GdkPixbuf::Pixbuf.new(src.colorspace, src.has_alpha?, src.bits_per_sample, w, h)
        s = src.pixels
        d = dst.pixels
        s_stride = src.rowstride
        d_stride = dst.rowstride
        row_len = tight

        h.times do |y|
          copy_span(d, y * d_stride, s, y * s_stride, row_len)
        end
        dst
      end

      def make_pixbuf_from_tight_bytes(w, h, n, colorspace, has_alpha, bps, bytestr)
        @_data_pool ||= []
        bin = bytestr.dup
        bin.force_encoding('ASCII-8BIT')
        @_data_pool << bin  # keep a hard ref so GC doesn't free the backing store

        GdkPixbuf::Pixbuf.new(
          data: bin,
          colorspace: colorspace,
          has_alpha: has_alpha,
          bits_per_sample: bps,
          width: w,
          height: h,
          rowstride: w * n
        )
      end

      def apply_grayscale(pixbuf)
        bytes, w, h, n, cs, has_a, bps = to_tight_bytes(pixbuf)
        tight = w * n
        has_alpha = (n > 3)

        h.times do |y|
          row = y * tight
          w.times do |x|
            off = row + x * n
            r = byte_get(bytes, off)
            g = byte_get(bytes, off + 1)
            b = byte_get(bytes, off + 2)
            gray = (0.299 * r + 0.587 * g + 0.114 * b).to_i
            byte_set(bytes, off,     gray)
            byte_set(bytes, off + 1, gray)
            byte_set(bytes, off + 2, gray)
            # alpha left as-is (off+3) if present
          end
        end

        make_pixbuf_from_tight_bytes(w, h, n, cs, has_a, bps, bytes)
      end

      def apply_border(pixbuf, color)
        base_bytes, w, h, n, cs, has_a, bps = to_tight_bytes(pixbuf)
        tight = w * n
        has_alpha = (n > 3)
        rgb = BORDER_COLORS[color] || BORDER_COLORS[:green]
        bw = BORDER_WIDTH

        # start from a copy of the base image
        out = base_bytes.dup

        # build solid mask from alpha (or everything solid if no alpha)
        solid = Array.new(h) { Array.new(w, true) }
        if has_alpha
          h.times do |y|
            row = y * tight
            w.times do |x|
              a = byte_get(base_bytes, row + x * n + 3)
              solid[y][x] = a && a > 0
            end
          end
        end

        neighbors = [[-1,0],[1,0],[0,-1],[0,1],[-1,-1],[1,1],[-1,1],[1,-1]]

        # edge detection + draw inward border
        h.times do |y|
          row = y * tight
          w.times do |x|
            next unless solid[y][x]
            edge = false
            neighbors.each do |dx, dy|
              nx = x + dx; ny = y + dy
              if nx < 0 || ny < 0 || nx >= w || ny >= h || !solid[ny][nx]
                edge = true; break
              end
            end
            next unless edge

            (0...bw).each do |dpx|
              neighbors.each do |dx, dy|
                px = x + dx * dpx
                py = y + dy * dpx
                next if px < 0 || py < 0 || px >= w || py >= h
                next if has_alpha && !solid[py][px]
                off = py * tight + px * n
                byte_set(out, off,     rgb[0])
                byte_set(out, off + 1, rgb[1])
                byte_set(out, off + 2, rgb[2])
                # leave alpha channel as-is
              end
            end
          end
        end

        make_pixbuf_from_tight_bytes(w, h, n, cs, has_a, bps, out)
      end
    end
  end
end

# Initialize cache on load
BarBar::Variants.initialize_cache if defined?(Gtk)