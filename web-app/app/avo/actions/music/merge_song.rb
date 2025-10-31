class Avo::Actions::Music::MergeSong < Avo::BaseAction
  self.name = "Merge Another Song Into This One"
  self.message = "Enter the ID of a duplicate song to merge into the current song. All data from that song will be transferred here, and the duplicate will be deleted."
  self.confirm_button_label = "Merge Song"
  self.standalone = true

  def fields
    field :source_song_id,
      as: :text,
      name: "Source Song ID (to be deleted)",
      help: "Enter the ID of the duplicate song that will be merged into the current song and deleted.",
      placeholder: "e.g., 123",
      required: true

    field :confirm_merge,
      as: :boolean,
      name: "I understand this action cannot be undone",
      default: false,
      help: "The source song will be permanently deleted after merging"
  end

  def handle(query:, fields:, current_user:, resource:, **args)
    target_song = query.first

    if query.count > 1
      return error "This action can only be performed on a single song at a time."
    end

    source_song_id = fields["source_song_id"]

    unless source_song_id.present?
      return error "Please enter the ID of the song to merge."
    end

    unless fields["confirm_merge"]
      return error "Please confirm you understand this action cannot be undone."
    end

    source_song = Music::Song.find_by(id: source_song_id)

    unless source_song
      return error "Song with ID #{source_song_id} not found."
    end

    if source_song.id == target_song.id
      return error "Cannot merge a song with itself. Please enter a different song ID."
    end

    result = ::Music::Song::Merger.call(source: source_song, target: target_song)

    if result.success?
      succeed "Successfully merged '#{source_song.title}' (ID: #{source_song.id}) into '#{target_song.title}'. The source song has been deleted."
    else
      error "Failed to merge songs: #{result.errors.join(", ")}"
    end
  end
end
