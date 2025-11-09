module Actions
  module Admin
    module Music
      class GenerateArtistDescription < Actions::Admin::BaseAction
        def self.name
          "Generate AI Description"
        end

        def self.message
          "This will generate AI descriptions for the selected artist(s) in the background."
        end

        def self.confirm_button_label
          "Generate Descriptions"
        end

        def call
          artist_ids = models.map(&:id)

          artist_ids.each do |artist_id|
            ::Music::ArtistDescriptionJob.perform_async(artist_id)
          end

          succeed "#{artist_ids.length} artist(s) queued for AI description generation."
        end
      end
    end
  end
end
