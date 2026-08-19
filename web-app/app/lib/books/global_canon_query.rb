module Books
  # The global canon selection algorithm, ported from the legacy site's
  # GlobalCanonGenerator.
  #
  # Walks the ranked books twice -- fiction first, then non-fiction -- taking a
  # book only when its country is under the cap and its author is unused. TWO
  # DETAILS ARE LOAD-BEARING and must not be tidied:
  #
  #   1. Fiction runs FIRST.
  #   2. The country and author counters are SHARED across both passes.
  #
  # Together they are why the non-fiction tail is more geographically
  # constrained than the fiction head: fiction has already spent the slots.
  # Reordering the passes produces a different canon, and a test pins it.
  #
  # A book with no country falls into the `nil` bucket, which is capped like any
  # other country. Legacy does this (`book.countries.first&.id`) and it is
  # deliberately preserved. Same for authors.
  class GlobalCanonQuery
    # Four books excluded by hand on the legacy site. The migration preserved
    # book ids, so these resolve 1:1 in this app.
    #
    #   2526  The Protocols of the Elders of Zion  antisemitic forgery
    #   1974  Mein Kampf
    #  15365  Revolt Against The Modern World      fascist esotericism
    #    705  The Elements of Style                a style manual, not literature
    BLOCKED_BOOK_IDS = [2526, 1974, 15365, 705].freeze

    FICTION_SLUG = "fiction".freeze
    NONFICTION_SLUG = "nonfiction".freeze

    Result = Struct.new(
      :ranked_items, :requested, :delivered, :blocked_by_country, :blocked_by_author,
      keyword_init: true
    )

    def self.call(ranking_configuration:, settings:)
      new(ranking_configuration: ranking_configuration, settings: settings).call
    end

    def initialize(ranking_configuration:, settings:)
      @ranking_configuration = ranking_configuration
      @settings = settings
      @country_used = Hash.new(0)
      @author_used = Hash.new(0)
      @blocked_by_country = 0
      @blocked_by_author = 0
    end

    def call
      nonfiction_quota = (@settings.total_books * @settings.nonfiction_percentage / 100.0).round
      fiction_quota = @settings.total_books - nonfiction_quota

      selected = select_pass(candidates_in(FICTION_SLUG), fiction_quota)
      selected += select_pass(candidates_in(NONFICTION_SLUG), nonfiction_quota)

      Result.new(
        ranked_items: ranked_items_for(selected),
        requested: @settings.total_books,
        delivered: selected.size,
        blocked_by_country: @blocked_by_country,
        blocked_by_author: @blocked_by_author
      )
    end

    private

    def select_pass(candidate_ids, quota)
      return [] if quota <= 0

      picked = []
      candidate_ids.each do |id|
        if @country_used[country_by_book[id]] >= @settings.max_books_per_country
          @blocked_by_country += 1
          next
        end
        if @author_used[author_by_book[id]] >= 1
          @blocked_by_author += 1
          next
        end

        picked << id
        @country_used[country_by_book[id]] += 1
        @author_used[author_by_book[id]] += 1
        break if picked.size >= quota
      end
      picked
    end

    # Rank-ordered book ids carrying the given genre. Legacy loaded every ranked
    # book as an AR object with two associations preloaded to answer a question
    # about integers; measured against production data that costs ~0.4s where
    # plucking costs a fraction of it, and most settings scan nearly the whole
    # ranked set anyway (250 books at 50% non-fiction reaches position 21,374 of
    # 24,242), so there is nothing to gain from batching with an early exit.
    def candidates_in(slug)
      category = ::Books::Category.active.find_by(slug: slug)
      return [] if category.nil?

      member_ids = ::CategoryItem
        .where(category_id: category.id, item_type: "Books::Book")
        .pluck(:item_id)
        .to_set

      ranked_ids.select { |id| member_ids.include?(id) }
    end

    def ranked_ids
      @ranked_ids ||= begin
        ids = ::RankedItem
          .where(ranking_configuration_id: @ranking_configuration.id, item_type: "Books::Book")
          .where.not(rank: nil)
          .where.not(item_id: BLOCKED_BOOK_IDS)
          .order(:rank)
          .pluck(:item_id)

        ids - excluded_book_ids
      end
    end

    def excluded_book_ids
      return [] if @settings.excluded_genres.blank?

      ::CategoryItem
        .where(category_id: @settings.excluded_genres.map(&:id), item_type: "Books::Book")
        .pluck(:item_id)
    end

    # `order(:id)` reproduces legacy's `book.countries.first`, which had no
    # explicit order and followed join-row insertion order in practice. Which row
    # wins is not cosmetic -- it decides which country bucket the book spends --
    # so it is pinned by a test.
    def country_by_book
      @country_by_book ||= first_per_book(
        ::Books::BookCountry.where(book_id: ranked_ids).order(:id).pluck(:book_id, :country_id)
      )
    end

    # `order(:position, :id)` reproduces `book.authors.first`, which follows the
    # `has_many :book_authors, -> { order(:position) }` association order.
    def author_by_book
      @author_by_book ||= first_per_book(
        ::Books::BookAuthor.where(book_id: ranked_ids).order(:position, :id).pluck(:book_id, :author_id)
      )
    end

    def first_per_book(pairs)
      pairs.each_with_object({}) { |(book_id, value), map| map[book_id] ||= value }
    end

    def ranked_items_for(ids)
      ::RankedItem
        .where(ranking_configuration_id: @ranking_configuration.id, item_type: "Books::Book", item_id: ids)
        .includes(item: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
        .order(:rank)
    end
  end
end
