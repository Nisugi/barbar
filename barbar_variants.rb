# QUIET
# barbar_variants.rb - Icon variant generation and caching system

module BarBar
  module Variants
    CACHE_VERSION = 2  # Bumped to invalidate old cache
    CACHE_DIR = File.join(ICON_FOLDER, 'cache', 'variants')
    MANIFEST_FILE = File.join(CACHE_DIR, 'manifest.yaml')
    
    class << self
      def initialize_cache
        require 'fileutils'
        FileUtils.mkdir_p(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
        @_data_pool = []
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
      
      def manage_data_pool
        if @_data_pool.size > MAX_DATA_POOL_SIZE
          # Keep the most recent half
          @_data_pool = @_data_pool.last(MAX_DATA_POOL_SIZE / 2)
        end
      end
      
      def make_pixbuf_from_pixels(src_pixbuf, pixels_str)
        bin = pixels_str.dup
        bin.force_encoding('ASCII-8BIT')
        @_data_pool << bin
        manage_data_pool
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
        
        # Parse variant string
        code = parse_variant_code(variant_string)
        
        "#{base_name}_#{icon_num}_#{code}"
      end
      
      def parse_variant_code(variant_string)
        return 'base' if variant_string.nil? || variant_string.empty?
        
        parts = []
        
        # Check for grayscale (now 'gs' instead of single letter)
        parts << 'gs' if variant_string.include?('gs')
        
        # Check for gradient (cg_RRGGBB_RRGGBB)
        if variant_string =~ /cg_([0-9a-fA-F]{6})_([0-9a-fA-F]{6})/
          parts << "cg_#{$1.downcase}_#{$2.downcase}"
        # Check for solid color (c_RRGGBB)
        elsif variant_string =~ /c_([0-9a-fA-F]{6})/
          parts << "c_#{$1.downcase}"
        end
        
        # Check for border width (bw_N)
        if variant_string =~ /bw_(\d+)/
          parts << "bw_#{$1}"
        end
        
        parts.empty? ? 'base' : parts.join('_')
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
        if variant_string.include?('gs')
          result = apply_grayscale(result)
        end
        
        # Extract border width if specified
        border_width = DEFAULT_BORDER_WIDTH
        if variant_string =~ /bw_(\d+)/
          border_width = $1.to_i.clamp(MIN_BORDER_WIDTH, MAX_BORDER_WIDTH)
        end
        
        # Then apply border if color is specified
        if variant_string =~ /cg_([0-9a-fA-F]{6})_([0-9a-fA-F]{6})/
          # Gradient border
          hex_color = "#{$1}_#{$2}"
          result = apply_border(result, hex_color, border_width)
        elsif variant_string =~ /c_([0-9a-fA-F]{6})/
          # Solid border
          hex_color = $1
          result = apply_border(result, hex_color, border_width)
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
        @_data_pool << bin
        manage_data_pool

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

      def hex_to_rgb(hex_string)
        # Ensure 6 character hex
        hex = hex_string.downcase
        return [0, 255, 0] unless hex =~ /^[0-9a-f]{6}$/
        
        r = hex[0..1].to_i(16)
        g = hex[2..3].to_i(16)
        b = hex[4..5].to_i(16)
        [r, g, b]
      end

      def apply_border(pixbuf, hex_color, border_width = nil)
        # Parse hex_color which might be "RRGGBB" or "RRGGBB_RRGGBB" for gradient
        colors = hex_color.split('_')
        start_rgb = hex_to_rgb(colors[0])
        end_rgb = colors[1] ? hex_to_rgb(colors[1]) : start_rgb
        is_gradient = colors.length > 1
        
        base_bytes, w, h, n, cs, has_a, bps = to_tight_bytes(pixbuf)
        tight = w * n
        has_alpha = (n > 3)
        bw = border_width || DEFAULT_BORDER_WIDTH

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
                
                # Calculate color (gradient or solid)
                if is_gradient
                  # Interpolate based on position
                  t = px.to_f / w.to_f  # Simple left-to-right gradient
                  r = (start_rgb[0] * (1-t) + end_rgb[0] * t).to_i
                  g = (start_rgb[1] * (1-t) + end_rgb[1] * t).to_i
                  b = (start_rgb[2] * (1-t) + end_rgb[2] * t).to_i
                else
                  r, g, b = start_rgb
                end
                
                off = py * tight + px * n
                byte_set(out, off,     r)
                byte_set(out, off + 1, g)
                byte_set(out, off + 2, b)
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