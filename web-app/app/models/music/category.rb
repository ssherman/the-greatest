# == Schema Information
#
# Table name: categories
#
#  id                :bigint           not null, primary key
#  alternative_names :string           default([]), is an Array
#  category_type     :integer          default(0)
#  deleted           :boolean          default(FALSE)
#  description       :text
#  import_source     :integer
#  item_count        :integer          default(0)
#  name              :string           not null
#  slug              :string
#  type              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  parent_id         :bigint
#
# Indexes
#
#  index_categories_on_category_type  (category_type)
#  index_categories_on_deleted        (deleted)
#  index_categories_on_name           (name)
#  index_categories_on_parent_id      (parent_id)
#  index_categories_on_slug           (slug)
#  index_categories_on_type           (type)
#  index_categories_on_type_and_slug  (type,slug)
#
# Foreign Keys
#
#  fk_rails_...  (parent_id => categories.id)
#
module Music
  class Category < ::Category
    # Music-specific associations
    has_many :albums, through: :category_items, source: :item, source_type: "Music::Album"
    has_many :songs, through: :category_items, source: :item, source_type: "Music::Song"
    has_many :artists, through: :category_items, source: :item, source_type: "Music::Artist"

    # Music-specific scopes
    scope :by_album_ids, ->(album_ids) { joins(:category_items).where(category_items: {item_type: "Music::Album", item_id: album_ids}) }
    scope :by_song_ids, ->(song_ids) { joins(:category_items).where(category_items: {item_type: "Music::Song", item_id: song_ids}) }
    scope :by_artist_ids, ->(artist_ids) { joins(:category_items).where(category_items: {item_type: "Music::Artist", item_id: artist_ids}) }
  end
end
