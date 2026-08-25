module Actions
  module Admin
    module Music
      class MergeAlbum < Actions::Admin::BaseAction
        def self.name
          "Merge Another Album Into This One"
        end

        def self.message
          "Enter the ID of a duplicate album to merge into the current album. The source album will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Album"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def self.destructive?
          true
        end

        def call
          return error("This action can only be performed on a single album.") if models.count != 1

          target_album = models.first

          source_album_id = fields[:source_album_id] || fields["source_album_id"]
          confirm_merge = fields[:confirm_merge] || fields["confirm_merge"]

          unless source_album_id.present?
            return error("Please enter the ID of the album to merge.")
          end

          unless confirm_merge == "1" || confirm_merge == true
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_album = ::Music::Album.find_by(id: source_album_id)

          unless source_album
            return error("Album with ID #{source_album_id} not found.")
          end

          if source_album.id == target_album.id
            return error("Cannot merge an album with itself. Please enter a different album ID.")
          end

          source_title = source_album.title
          source_id = source_album.id

          merger = ::Music::Album::Merger.new(source: source_album, target: target_album)
          result = merger.call

          if result.success?
            message = "Successfully merged '#{source_title}' (ID: #{source_id}) into '#{target_album.title}'. The source album has been deleted."

            if merger.stats[:post_commit_error].present?
              warn "#{message} Note: search reindexing and ranking recalculation could not be " \
                "scheduled (#{merger.stats[:post_commit_error]}); they will need to be re-run."
            else
              succeed message
            end
          else
            error "Failed to merge albums: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
