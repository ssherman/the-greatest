class Avo::Actions::Music::MergeAlbum < Avo::BaseAction
  self.name = "Merge Another Album Into This One"
  self.message = "Enter the ID of a duplicate album to merge into the current album. All data from that album will be transferred here, and the duplicate will be deleted."
  self.confirm_button_label = "Merge Album"
  self.standalone = true

  def fields
    field :source_album_id,
      as: :text,
      name: "Source Album ID (to be deleted)",
      help: "Enter the ID of the duplicate album that will be merged into the current album and deleted.",
      placeholder: "e.g., 123",
      required: true

    field :confirm_merge,
      as: :boolean,
      name: "I understand this action cannot be undone",
      default: false,
      help: "The source album will be permanently deleted after merging"
  end

  def handle(query:, fields:, current_user:, resource:, **args)
    target_album = query.first

    if query.count > 1
      return error "This action can only be performed on a single album at a time."
    end

    source_album_id = fields["source_album_id"]

    unless source_album_id.present?
      return error "Please enter the ID of the album to merge."
    end

    unless fields["confirm_merge"]
      return error "Please confirm you understand this action cannot be undone."
    end

    source_album = Music::Album.find_by(id: source_album_id)

    unless source_album
      return error "Album with ID #{source_album_id} not found."
    end

    if source_album.id == target_album.id
      return error "Cannot merge an album with itself. Please enter a different album ID."
    end

    result = ::Music::Album::Merger.call(source: source_album, target: target_album)

    if result.success?
      succeed "Successfully merged '#{source_album.title}' (ID: #{source_album.id}) into '#{target_album.title}'. The source album has been deleted."
    else
      error "Failed to merge albums: #{result.errors.join(", ")}"
    end
  end
end
