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

        def self.destructive?
          true
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

          source_name = source_artist.name
          source_id = source_artist.id

          merger = ::Music::Artist::Merger.new(source: source_artist, target: target_artist)
          result = merger.call

          if result.success?
            message = "Successfully merged '#{source_name}' (ID: #{source_id}) into '#{target_artist.name}'. The source artist has been deleted."

            if merger.stats[:post_commit_error].present?
              warn "#{message} Note: search reindexing and ranking recalculation could not be " \
                "scheduled (#{merger.stats[:post_commit_error]}); they will need to be re-run."
            else
              succeed message
            end
          else
            error "Failed to merge artists: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
