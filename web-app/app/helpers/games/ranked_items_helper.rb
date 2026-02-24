module Games::RankedItemsHelper
  def games_page_title(year_filter)
    if year_filter
      "#{games_year_title_phrase(year_filter)} | The Greatest Games"
    else
      "Greatest Video Games of All Time | The Greatest Games"
    end
  end

  def games_page_description(year_filter)
    if year_filter
      "Discover the greatest video games #{games_year_description_phrase(year_filter)}. " \
        "Our definitive ranking features the most acclaimed and influential games."
    else
      "Our definitive ranking of the greatest video games ever made. " \
        "From classic titles to modern masterpieces, discover the games that defined the medium."
    end
  end

  def games_page_heading(year_filter)
    year_filter ? games_year_title_phrase(year_filter) : "Greatest Video Games of All Time"
  end

  private

  def games_year_title_phrase(year_filter)
    case year_filter.type
    when :decade
      "Greatest Video Games of the #{year_filter.display}"
    when :range
      "Greatest Video Games from #{year_filter.start_year} to #{year_filter.end_year}"
    when :single
      "Greatest Video Games of #{year_filter.display}"
    when :since
      "Greatest Video Games Since #{year_filter.start_year}"
    when :through
      "Greatest Video Games Through #{year_filter.end_year}"
    end
  end

  def games_year_description_phrase(year_filter)
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
