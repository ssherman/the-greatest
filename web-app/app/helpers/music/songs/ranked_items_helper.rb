module Music::Songs::RankedItemsHelper
  include Music::RankedItemsHelper

  def songs_page_title(year_filter)
    if year_filter
      "#{year_title_phrase(year_filter, "Songs")} | The Greatest Music"
    else
      "Top 100 Greatest Songs of All Time | The Greatest Music"
    end
  end

  def songs_page_description(year_filter)
    if year_filter
      "Discover the greatest songs #{year_description_phrase(year_filter)}. " \
        "Our definitive ranking features the most acclaimed and influential tracks."
    else
      "Our definitive ranking of the 100 greatest songs ever recorded. " \
        "From classic rock to modern masterpieces, discover the songs that changed music."
    end
  end

  def songs_page_heading(year_filter)
    year_filter ? year_title_phrase(year_filter, "Songs") : "Top Songs"
  end
end
