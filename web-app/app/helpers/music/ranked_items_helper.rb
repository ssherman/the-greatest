module Music::RankedItemsHelper
  def year_title_phrase(year_filter, item_type)
    case year_filter.type
    when :decade
      "Greatest #{item_type} of the #{year_filter.display}"
    when :range
      "Greatest #{item_type} from #{year_filter.start_year} to #{year_filter.end_year}"
    when :single
      "Greatest #{item_type} of #{year_filter.display}"
    when :since
      "Greatest #{item_type} Since #{year_filter.start_year}"
    when :through
      "Greatest #{item_type} Through #{year_filter.end_year}"
    end
  end

  def year_description_phrase(year_filter)
    case year_filter.type
    when :decade
      "of the #{year_filter.display}"
    when :range
      "from #{year_filter.start_year} to #{year_filter.end_year}"
    when :single
      "from #{year_filter.display}"
    when :since
      "since #{year_filter.start_year}"
    when :through
      "through #{year_filter.end_year}"
    end
  end
end
