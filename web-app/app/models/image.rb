class Image < ApplicationRecord
  belongs_to :parent, polymorphic: true

  has_one_attached :file do |attachable|
    attachable.variant :small, resize_to_limit: [100, 100]
    attachable.variant :medium, resize_to_limit: [150, 150]
    attachable.variant :large, resize_to_limit: [250, 250]
  end

  store :metadata, accessors: [:analyzed, :identified], coder: ActiveRecord::Coders::JSON

  validates :file, presence: true
  validates :primary, inclusion: {in: [true, false]}
  validate :acceptable_image_format

  # Scopes
  scope :primary, -> { where(primary: true) }
  scope :non_primary, -> { where(primary: false) }

  # Callbacks
  after_save :unset_other_primary_images, if: -> { saved_change_to_primary? && primary? }

  private

  def acceptable_image_format
    return unless file.attached?

    unless file.blob.content_type.in?(%w[image/jpeg image/png image/webp image/gif])
      errors.add(:file, "must be a JPEG, PNG, WebP, or GIF")
    end
  end

  def unset_other_primary_images
    # Use update_all to avoid callbacks and validations on other records
    # This safely ensures only one primary image per parent
    parent.images.where.not(id: id).update_all(primary: false)
  end
end
