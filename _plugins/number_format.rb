module Jekyll
  module NumberFormatFilter
    # Format a number with thousands separators. Keeps decimal part if present.
    def number_with_commas(input)
      return input if input.nil? || input == ''
      s = input.to_s
      int, frac = s.split('.', 2)
      int = int.gsub(/\B(?=(\d{3})+(?!\d))/, ',')
      frac ? "#{int}.#{frac}" : int
    end
  end
end

Liquid::Template.register_filter(Jekyll::NumberFormatFilter)
