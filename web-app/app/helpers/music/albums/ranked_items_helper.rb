module Music::Albums::RankedItemsHelper
  include Music::RankedItemsHelper

  def albums_page_title(year_filter)
    if year_filter
      "#{year_title_phrase(year_filter, "Albums")} | The Greatest Music"
    else
      "Greatest Albums of All Time | The Greatest Music"
    end
  end

  def albums_page_description(year_filter)
    if year_filter
      "Discover the greatest albums #{year_description_phrase(year_filter)}. " \
        "Our definitive ranking features the most acclaimed and influential records."
    else
      "Our definitive ranking of the 100 greatest albums ever recorded. " \
        "From classic rock to modern masterpieces, discover the albums that changed music."
    end
  end

  def albums_page_heading(year_filter)
    year_filter ? year_title_phrase(year_filter, "Albums") : "Greatest Albums of All Time"
  end
end
