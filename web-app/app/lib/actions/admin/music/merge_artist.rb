module Actions
  module Admin
    module Music
      class MergeArtist < Actions::Admin::BaseAction
        def self.name
          "Merge Another Artist Into This One"
        end

        def self.message
          "Enter the ID of a duplicate artist to merge into the current artist. The source artist will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Artist"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def call
          return error("This action can only be performed on a single artist.") if models.count != 1

          target_artist = models.first

          source_artist_id = fields[:source_artist_id] || fields["source_artist_id"]
          confirm_merge = fields[:confirm_merge] || fields["confirm_merge"]

          unless source_artist_id.present?
            return error("Please select an artist to merge.")
          end

          unless confirm_merge == "1" || confirm_merge == true
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_artist = ::Music::Artist.find_by(id: source_artist_id)

          unless source_artist
            return error("Artist with ID #{source_artist_id} not found.")
          end

          if source_artist.id == target_artist.id
            return error("Cannot merge an artist with itself. Please select a different artist.")
          end

          result = ::Music::Artist::Merger.call(source: source_artist, target: target_artist)

          if result.success?
            succeed "Successfully merged '#{source_artist.name}' (ID: #{source_artist.id}) into '#{target_artist.name}'. The source artist has been deleted."
          else
            error "Failed to merge artists: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
