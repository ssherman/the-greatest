# == Schema Information
#
# Table name: news_topics
#
#  id         :bigint           not null, primary key
#  domain     :integer          not null
#  name       :string           not null
#  slug       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_news_topics_on_domain_and_slug  (domain,slug) UNIQUE
#
class NewsTopic < ApplicationRecord
  extend FriendlyId

  # Scoped to :domain, so books and music may each hold a "site-news".
  # :finders is deliberately absent -- with a scoped slug, NewsTopic.find("x")
  # could resolve to another domain's row. Always scope first, then
  # .friendly.find.
  friendly_id :name, use: [:slugged, :scoped], scope: :domain

  # Reserved on this model rather than in config/initializers/friendly_id.rb:
  # FriendlyId.defaults applies that initializer to all 18 friendly_id models here,
  # and two live rows already hold the slug "page" (books_books 130620, categories
  # 49860) -- reserving it globally makes them fail validation on every save.
  friendly_id_config.reserved_words += %w[topic page]

  # Same integer mapping as DomainRole so the two can never disagree about
  # which site an integer means.
  enum :domain, {music: 0, games: 1, books: 2, movies: 3}

  has_many :news_post_topics, dependent: :destroy
  has_many :news_posts, through: :news_post_topics

  validates :name, presence: true
  validates :domain, presence: true

  scope :sorted_by_name, -> { order(:name) }

  def to_param = slug

  # FriendlyId's own Slugged default never regenerates an existing slug on
  # rename (it only fires when the slug is nil), but the Scoped module we also
  # use DOES regenerate whenever the scope column (:domain) changes. A topic's
  # slug is a public URL, so this override blocks that: once set, the slug is
  # frozen no matter what changes on the record. Category is different -- it
  # additionally opts back into regeneration on rename via `name_changed? ||
  # super`; this model deliberately does not.
  def should_generate_new_friendly_id? = slug.blank?
end
