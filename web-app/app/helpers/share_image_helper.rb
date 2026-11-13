# Picks the cover URL a link preview may use. Messaging apps and social cards
# render a small summary thumbnail, and a tiny or unmeasured image looks broken
# there, so an image qualifies only when its stored blob metadata proves both
# sides are at least MIN_DIMENSION. Covers migrated without analysis have no
# width/height and are skipped rather than guessed at.
module ShareImageHelper
  MIN_DIMENSION = 200

  def share_image_url(image)
    return unless image&.file&.attached?

    metadata = image.file.blob.metadata
    width = metadata["width"]
    height = metadata["height"]
    return unless width.is_a?(Numeric) && height.is_a?(Numeric)
    return if width < MIN_DIMENSION || height < MIN_DIMENSION

    rails_public_blob_url(image.file)
  end
end
