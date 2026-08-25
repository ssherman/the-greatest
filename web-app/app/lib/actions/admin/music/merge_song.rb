module Actions
  module Admin
    module Music
      class MergeSong < Actions::Admin::BaseAction
        def self.name
          "Merge Another Song Into This One"
        end

        def self.message
          "Enter the ID of a duplicate song to merge into the current song. The source song will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Song"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def self.destructive?
          true
        end

        def call
          return error("This action can only be performed on a single song.") if models.count != 1

          target_song = models.first

          source_song_id = fields[:source_song_id] || fields["source_song_id"]
          confirm_merge = fields[:confirm_merge] || fields["confirm_merge"]

          unless source_song_id.present?
            return error("Please enter the ID of the song to merge.")
          end

          unless confirm_merge == "1" || confirm_merge == true
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_song = ::Music::Song.find_by(id: source_song_id)

          unless source_song
            return error("Song with ID #{source_song_id} not found.")
          end

          if source_song.id == target_song.id
            return error("Cannot merge a song with itself. Please enter a different song ID.")
          end

          source_title = source_song.title
          source_id = source_song.id

          merger = ::Music::Song::Merger.new(source: source_song, target: target_song)
          result = merger.call

          if result.success?
            message = "Successfully merged '#{source_title}' (ID: #{source_id}) into '#{target_song.title}'. The source song has been deleted."

            if merger.stats[:post_commit_error].present?
              warn "#{message} Note: ranking recalculation could not be scheduled " \
                "(#{merger.stats[:post_commit_error]}); it will need to be re-run."
            else
              succeed message
            end
          else
            error "Failed to merge songs: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
