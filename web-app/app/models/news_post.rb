# == Schema Information
#
# Table name: news_posts
#
#  id           :bigint           not null, primary key
#  body         :text             not null
#  domain       :integer          not null
#  published_at :datetime
#  slug         :string           not null
#  summary      :text
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
# Indexes
#
#  index_news_posts_on_domain_and_published_at  (domain,published_at DESC)
#  index_news_posts_on_domain_and_slug          (domain,slug) UNIQUE
#  index_news_posts_on_user_id                  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class NewsPost < ApplicationRecord
  extend FriendlyId

  EXCERPT_LIMIT = 200

  # Lives on the model rather than on NewsPostsController because
  # Services::News::CachedUrls has to derive the same page count the public
  # index paginates by; two copies of "10" would drift the moment one changed
  # and would silently leave the last index page uncached.
  PER_PAGE = 10

  # Scoped to :domain -- books and music may each hold a "december-update".
  # :finders is deliberately absent: with a scoped slug a bare find("x") could
  # resolve to another domain's post. Always scope first, then .friendly.find.
  friendly_id :title, use: [:slugged, :scoped], scope: :domain

  # Reserved on this model rather than in config/initializers/friendly_id.rb:
  # FriendlyId.defaults applies that initializer to all 18 friendly_id models here,
  # and two live rows already hold the slug "page" (books_books 130620, categories
  # 49860) -- reserving it globally makes them fail validation on every save.
  friendly_id_config.reserved_words += %w[topic page]

  # Same integer mapping as DomainRole so the two can never disagree about
  # which site an integer means.
  enum :domain, {music: 0, games: 1, books: 2, movies: 3}

  belongs_to :user
  has_many :news_post_topics, dependent: :destroy
  has_many :news_topics, through: :news_post_topics

  # Its own attachment rather than the polymorphic Image model: Image's variants
  # cap at 250x250 with preprocessed: true, so widening them would touch every
  # book cover and album art record in the app.
  has_one_attached :share_image do |attachable|
    attachable.variant :card, resize_to_limit: [1200, 630], preprocessed: true
  end

  # Uploaded in admin; the author pastes the returned URL into the body as
  # ![alt](url). No editor integration.
  has_many_attached :body_images

  validates :title, presence: true
  validates :body, presence: true
  validates :domain, presence: true

  # A NULL published_at is excluded by SQL three-valued logic -- NULL <= now is
  # NULL, which is not true -- so this single predicate covers drafts and
  # future-dated posts alike.
  scope :published, -> { where(published_at: ..Time.current) }
  scope :recent, -> { order(published_at: :desc, id: :desc) }

  def published? = published_at.present? && published_at <= Time.current

  def draft? = !published?

  # Summary when the author wrote one, otherwise plain text derived from the
  # RENDERED body. Deriving from the Markdown source instead would leak "**"
  # and "[]()" into meta descriptions and the feed.
  def excerpt(limit: EXCERPT_LIMIT)
    return summary if summary.present?

    text = Services::News::PlainText.call(Services::News::BodyRenderer.call(body))
    text.truncate(limit, separator: " ")
  end

  def to_param = slug

  # A published post's URL is a permanent link, so retitling must not move it.
  def should_generate_new_friendly_id? = slug.blank?
end
