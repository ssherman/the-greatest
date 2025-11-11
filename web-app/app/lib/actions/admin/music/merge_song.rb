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

          result = ::Music::Song::Merger.call(source: source_song, target: target_song)

          if result.success?
            succeed "Successfully merged '#{source_song.title}' (ID: #{source_song.id}) into '#{target_song.title}'. The source song has been deleted."
          else
            error "Failed to merge songs: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
