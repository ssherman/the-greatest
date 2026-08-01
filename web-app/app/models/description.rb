# == Schema Information
#
# Table name: descriptions
#
#  id               :bigint           not null, primary key
#  content          :text             not null
#  describable_type :string           not null
#  kind             :integer          default(0), not null
#  license          :integer
#  locale           :string           default("en"), not null
#  rank             :integer          default(0), not null
#  retrieved_at     :datetime
#  source           :integer          not null
#  source_name      :string
#  source_url       :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  describable_id   :bigint           not null
#
# Indexes
#
#  index_descriptions_on_describable          (describable_type,describable_id)
#  index_descriptions_on_describable_and_key  (describable_type,describable_id,kind,locale,source,source_name) UNIQUE NULLS NOT DISTINCT
#  index_descriptions_one_preferred_per_key   (describable_type,describable_id,kind,locale) UNIQUE WHERE (rank = 1)
#
class Description < ApplicationRecord
  belongs_to :describable, polymorphic: true

  enum :kind, {summary: 0, long: 1, first_sentence: 2, blurb: 3}
  enum :rank, {deprecated: -1, normal: 0, preferred: 1}
  enum :license, {cc0: 0, cc_by_sa_4: 1, proprietary: 2}, prefix: true
  enum :source, {manual: 0, ai_generated: 1, wikipedia: 2, openlibrary: 3,
                 musicbrainz: 4, igdb: 5, publisher: 6, goodreads: 7, other: 9},
    prefix: true

  normalizes :source_name, with: ->(value) { value.presence }

  validates :content, presence: true
  validates :locale, presence: true
  validates :source, presence: true
  validates :source_name, presence: true, if: :source_other?
  validates :source_name, absence: true, unless: :source_other?
  validates :source, uniqueness: {
    scope: [:describable_type, :describable_id, :kind, :locale, :source_name]
  }
end
