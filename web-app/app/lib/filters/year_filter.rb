module Filters
  class YearFilter
    DECADE_PATTERN = /^(\d{4})s$/
    RANGE_PATTERN = /^(\d{4})-(\d{4})$/
    SINGLE_PATTERN = /^(\d{4})$/

    Result = Struct.new(:start_year, :end_year, :display, :type, keyword_init: true)

    def self.parse(param, mode: nil)
      return nil if param.blank?

      # Handle open-ended ranges via mode parameter
      if mode == "since"
        year = extract_year(param)
        return Result.new(start_year: year, end_year: nil, display: param, type: :since)
      elsif mode == "through"
        year = extract_year(param)
        return Result.new(start_year: nil, end_year: year, display: param, type: :through)
      end

      case param
      when DECADE_PATTERN
        start_year = $1.to_i
        Result.new(start_year: start_year, end_year: start_year + 9, display: param, type: :decade)
      when RANGE_PATTERN
        start_year, end_year = $1.to_i, $2.to_i
        raise ArgumentError, "Start year must be less than or equal to end year" if start_year > end_year
        Result.new(start_year: start_year, end_year: end_year, display: param, type: :range)
      when SINGLE_PATTERN
        year = $1.to_i
        Result.new(start_year: year, end_year: year, display: param, type: :single)
      else
        raise ArgumentError, "Invalid year format: #{param}"
      end
    end

    def self.extract_year(param)
      raise ArgumentError, "Invalid year format: #{param}" unless param.match?(SINGLE_PATTERN)
      param.to_i
    end
    private_class_method :extract_year
  end
end
