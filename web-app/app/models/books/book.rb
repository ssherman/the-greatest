# == Schema Information
#
# Table name: books_books
#
#  id                   :bigint           not null, primary key
#  alternate_titles     :string           default([]), not null, is an Array
#  amazon_enriched_at   :datetime
#  book_kind            :integer          default(0), not null
#  book_length          :integer
#  description          :text
#  first_published_year :integer
#  page_range           :string
#  slug                 :string           not null
#  sort_title           :string
#  subtitle             :string
#  title                :string           not null
#  word_count           :integer
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  default_edition_id   :bigint
#  original_language_id :bigint
#
# Indexes
#
#  index_books_books_on_alternate_titles      (alternate_titles) USING gin
#  index_books_books_on_book_kind             (book_kind)
#  index_books_books_on_default_edition_id    (default_edition_id)
#  index_books_books_on_first_published_year  (first_published_year)
#  index_books_books_on_original_language_id  (original_language_id)
#  index_books_books_on_slug                  (slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (default_edition_id => books_editions.id) ON DELETE => nullify
#  fk_rails_...  (original_language_id => languages.id)
#
class Books::Book < ApplicationRecord
  include Describable
  include SearchIndexable
  include Reviewable
  include Correctable

  extend FriendlyId

  # Most titles slug from the title exactly as `friendly_id :title` would. But a
  # few titles slugify to a FriendlyId reserved word (e.g. "Images", "Users" — see
  # config/initializers/friendly_id.rb), which would raise a validation error. For
  # ONLY those, slug_candidates supplies a "<title> book" fallback instead; every
  # other title keeps its plain-title slug and FriendlyId's normal duplicate-title
  # conflict handling, unchanged.
  friendly_id :slug_candidates, use: [:slugged, :finders]

  enum :book_kind, {standalone: 0, collection: 1}

  # page_range and word_count are transitional. Page data belongs on the edition
  # (books_editions.page_count), but that column is empty for every book: legacy's
  # editions table carries no page or word counts, so the only source is these
  # work-level values. They exist to keep book_length derivable until a real
  # per-edition source arrives, and should go away when one does.
  enum :book_length, {very_short: 0, short: 1, medium: 2, moderate: 3, long: 4, very_long: 5}

  # The category types that participate in similarity scoring. Books carry no
  # `theme` categories today; counting only the scoring types keeps
  # similarity_category_count honest if that changes.
  SIMILARITY_CATEGORY_TYPES = %w[genre subject location].freeze

  # What a reader may propose a correction to. Ordered as the public form renders
  # them.
  #
  # Deliberately absent: sort_title, book_kind and book_length are not visible to a
  # reader, so a reader cannot know they are wrong; book_length is derived anyway.
  #
  # description is target: :description, not a column. books_books.description is
  # read by no book page and is scheduled for deletion; the displayed text lives in
  # the descriptions table.
  correctable_field :title, type: :string
  correctable_field :subtitle, type: :string
  correctable_field :first_published_year, type: :integer
  correctable_field :page_range, type: :string, hint: "A number or a range, e.g. 300 or 250-350"
  correctable_field :word_count, type: :integer
  correctable_field :alternate_titles, type: :string_array
  correctable_field :description, type: :text, target: :description

  belongs_to :original_language, class_name: "Language", optional: true
  belongs_to :default_edition, class_name: "Books::Edition", optional: true
  has_many :book_authors, -> { order(:position) }, class_name: "Books::BookAuthor", dependent: :destroy
  has_many :authors, through: :book_authors, class_name: "Books::Author"
  has_many :editions, class_name: "Books::Edition", dependent: :destroy

  has_many :credits, as: :creditable, class_name: "Books::Credit", dependent: :destroy
  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :category_items, as: :item, dependent: :destroy, inverse_of: :item
  has_many :categories, through: :category_items, class_name: "Books::Category"
  has_many :book_countries, class_name: "Books::BookCountry", dependent: :destroy
  has_many :countries, through: :book_countries, class_name: "Books::Country"
  has_many :list_items, as: :listable, dependent: :destroy
  has_many :lists, through: :list_items
  has_many :user_list_items, as: :listable, dependent: :destroy
  has_many :user_lists, through: :user_list_items
  has_many :ranked_items, as: :item, dependent: :destroy
  # Scoped so bulk indexing preloads one row per book instead of every configuration's
  # rank. The lambda runs once per preload, not once per record, so a 1,000-book batch
  # costs one extra query and the value is always read live -- no cache to go stale.
  has_one :primary_ranked_item,
    -> { where(ranking_configuration_id: Books::RankingConfiguration.default_primary&.id) },
    as: :item, class_name: "RankedItem"
  has_many :series_books, class_name: "Books::SeriesBook", dependent: :destroy
  has_many :series, through: :series_books, class_name: "Books::Series"
  has_many :book_relationships, class_name: "Books::BookRelationship", dependent: :destroy
  has_many :related_books, through: :book_relationships, class_name: "Books::Book"
  has_many :inverse_book_relationships, class_name: "Books::BookRelationship", foreign_key: :related_book_id, dependent: :destroy

  validates :title, presence: true

  before_validation :normalize_title
  before_validation :derive_book_length,
    if: -> { book_length.blank? && (page_range_changed? || word_count_changed?) }

  scope :selectable, -> { where(book_kind: :standalone) }

  def release_year
    first_published_year
  end

  # Correctable hook. derive_book_length only fires when book_length is blank, so
  # correcting page_range or word_count on a book that already has a length would
  # leave the "Length" and "Pages" rows of the public details card contradicting
  # each other. Clearing it lets the existing before_validation re-derive on save.
  def correction_applied(field_names)
    return unless field_names.intersect?(%w[page_range word_count])

    self.book_length = nil
  end

  # {file_attachment: :blob}, not a bare :primary_image -- the row and its
  # cover-image variant components go through the ActiveStorage attachment and
  # blob, not just the Image row, and both need to be preloaded or `.attached?`
  # and the URL helper each cost one query per row. Same shape as
  # Books::AuthorsController's ranked_books/all_books_relation preloads.
  def self.review_row_includes
    [{primary_image: {file_attachment: :blob}}, {book_authors: :author}]
  end

  def self.review_title_order
    "COALESCE(books_books.sort_title, books_books.title)"
  end

  # EXISTS rather than a join to books_authors: a book with three reviews and two
  # authors would otherwise come back three times over, which silently inflates
  # both the page and its count.
  def self.review_text_search(scope, term)
    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    scope.where(
      "books_books.title ILIKE :pattern OR EXISTS (
         SELECT 1 FROM books_book_authors
         INNER JOIN books_authors ON books_authors.id = books_book_authors.author_id
         WHERE books_book_authors.book_id = books_books.id
           AND books_authors.name ILIKE :pattern
       )",
      pattern: pattern
    )
  end

  def self.ranking_configuration_class
    ::Books::RankingConfiguration
  end

  # Same association walk as Books::CardComponent#author_names and
  # books/books/show.html.erb -- book_authors is already ordered by position,
  # so no additional sort is needed here.
  def self.review_creator_names(record)
    record.book_authors.map { |book_author| book_author.author.name }
  end

  def self.review_public_path(record)
    Rails.application.routes.url_helpers.book_path(record.slug)
  end

  def as_indexed_json
    active = categories.select { |c| c.deleted == false }
    scored = active.select { |c| SIMILARITY_CATEGORY_TYPES.include?(c.category_type) }

    {
      title: title,
      subtitle: subtitle,
      alternate_titles: alternate_titles,
      author_names: authors.map(&:name),
      author_ids: authors.map(&:id),
      category_ids: active.map(&:id),
      genre_category_ids: scored.select { |c| c.category_type == "genre" }.map(&:id),
      subject_category_ids: scored.select { |c| c.category_type == "subject" }.map(&:id),
      location_category_ids: scored.select { |c| c.category_type == "location" }.map(&:id),
      similarity_category_count: scored.size,
      book_kind: book_kind,
      first_published_year: first_published_year,
      original_language_id: original_language_id,
      country_ids: countries.map(&:id),
      book_length: self.class.book_lengths[book_length],
      ranked: list_items.any?,
      ranked_position: primary_ranked_item&.rank
    }
  end

  private

  def normalize_title
    self.title = Services::Text::QuoteNormalizer.call(title) if title.present?
  end

  def derive_book_length
    self.book_length = Books::BookLength.call(page_range: page_range, word_count: word_count)
  end

  def slug_candidates
    words = friendly_id_config.reserved_words
    return title unless words.present? && words.include?(normalize_friendly_id(title))
    ["#{title} book"]
  end
end
