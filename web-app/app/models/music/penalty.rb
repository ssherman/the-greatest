module Music
  class Penalty < ::Penalty
    # Music-specific penalty logic can be added here

    # Example of a dynamic penalty for music
    def calculate_penalty_value(list, ranking_configuration)
      return super unless dynamic?

      # Example: Penalty based on English-language bias
      if name.include?("English")
        # Check if list has mostly English-language albums
        english_albums_count = list.list_items.joins(:listable)
          .where("albums.language = ?", "English")
          .count
        total_items = list.list_items.count

        if total_items > 0 && (english_albums_count.to_f / total_items) > 0.8
          return penalty_applications.find_by(ranking_configuration: ranking_configuration)&.value || 18
        end
      end

      super
    end
  end
end
