module Actions
  module Admin
    module Music
      class GenerateAlbumDescription < Actions::Admin::BaseAction
        def self.name
          "Generate AI Description"
        end

        def self.message
          "This will generate AI descriptions for the selected album(s) in the background."
        end

        def self.confirm_button_label
          "Generate Descriptions"
        end

        def call
          album_ids = models.map(&:id)

          album_ids.each do |album_id|
            ::Music::AlbumDescriptionJob.perform_async(album_id)
          end

          succeed "#{album_ids.length} album(s) queued for AI description generation."
        end
      end
    end
  end
end
