module Books
  class FilterTitle
    def self.call(**options)
      new(**options).call
    end

    def initialize(categories: [], countries: [], year_start: nil, year_end: nil)
      @categories = categories || []
      @countries = countries || []
      @year_start = year_start.presence
      @year_end = year_end.presence
    end

    def call
      parts = ["The Greatest"]
      parts << @countries.map { |country| country.name.titlecase }.join(", ") if @countries.any?
      parts.concat(genre_parts)
      parts << date_phrase
      parts << "on #{format_list(names_for(:subject))}" if names_for(:subject).any?
      parts << "Set in #{format_list(names_for(:location))}" if names_for(:location).any?
      parts.join(" ")
    end

    private

    def genre_parts
      names = names_for(:genre)
      return ["Books"] if names.empty?

      parts = [format_list(names)]
      parts << "Books" unless names.any? { |name| name.end_with?("s") }
      parts
    end

    def date_phrase
      return "of #{@year_start}" if @year_start && @year_start == @year_end
      return "From #{@year_start} to #{@year_end}" if @year_start && @year_end
      return "Since #{@year_start}" if @year_start
      return "To #{@year_end}" if @year_end

      "of All Time"
    end

    def names_for(category_type)
      @names_for ||= {}
      @names_for[category_type] ||= @categories
        .select { |category| category.category_type.to_s == category_type.to_s }
        .map { |category| category.name.titlecase }
    end

    def format_list(names)
      case names.length
      when 1 then names.first
      when 2 then names.join(" and ")
      else "#{names[0..-2].join(", ")}, and #{names.last}"
      end
    end
  end
end
