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

      selected = select_pass(FICTION_SLUG, fiction_quota)
      selected += select_pass(NONFICTION_SLUG, nonfiction_quota)

      Result.new(
        ranked_items: ranked_items_for(selected),
        requested: @settings.total_books,
        delivered: selected.size,
        blocked_by_country: @blocked_by_country,
        blocked_by_author: @blocked_by_author
      )
    end

    private

    # `quota <= 0` returns before `candidates_in` runs, so e.g. a
    # 100%-non-fiction request never builds (and discards) the fiction
    # candidate set. Legacy guarded the same way, before it built its query.
    def select_pass(slug, quota)
      return [] if quota <= 0

      picked = []
      candidates_in(slug).each do |id|
        # Country is checked first, so a book that is both over its country
        # cap and by an already-used author is attributed to country only and
        # never reaches the author check below. Legacy skipped on
        # `country || author` in a single check and never separated the two --
        # this attribution is new information legacy never produced.
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

    # Rank-ordered book ids carrying the given genre. Genre membership is
    # applied as a subquery on `ranked_scope`, not a materialised member-id
    # array -- see `ranked_scope` for why that matters.
    def candidates_in(slug)
      category = ::Books::Category.active.find_by(slug: slug)
      return [] if category.nil?

      ranked_scope
        .where(item_id: ::CategoryItem.where(category_id: category.id, item_type: "Books::Book").select(:item_id))
        .order(:rank)
        .pluck(:item_id)
    end

    # The ranked, unblocked, un-excluded `RankedItem` relation -- kept as a
    # relation, never plucked into a Ruby array here, so every downstream use
    # composes it as a SQL subquery instead of a bind-parameter IN list.
    # PostgreSQL caps a statement at 65,535 bind parameters; a ranking
    # configuration with more ranked items than that would turn a plucked
    # array passed back in as literal ids into a silent 500 on a public page.
    # 24,242 books are ranked today; 126,303 exist.
    def ranked_scope
      @ranked_scope ||= begin
        scope = ::RankedItem
          .where(ranking_configuration_id: @ranking_configuration.id, item_type: "Books::Book")
          .where.not(rank: nil)
          .where.not(item_id: BLOCKED_BOOK_IDS)

        if @settings.excluded_genres.present?
          scope = scope.where.not(
            item_id: ::CategoryItem
              .where(category_id: @settings.excluded_genres.map(&:id), item_type: "Books::Book")
              .select(:item_id)
          )
        end

        scope
      end
    end

    # `order(:id)` reproduces legacy's `book.countries.first`, which had no
    # explicit order and followed join-row insertion order in practice. Which row
    # wins is not cosmetic -- it decides which country bucket the book spends --
    # so it is pinned by a test.
    def country_by_book
      @country_by_book ||= first_per_book(
        ::Books::BookCountry.where(book_id: ranked_scope.select(:item_id)).order(:id).pluck(:book_id, :country_id)
      )
    end

    # `order(:position, :id)` reproduces `book.authors.first`, which follows the
    # `has_many :book_authors, -> { order(:position) }` association order.
    def author_by_book
      @author_by_book ||= first_per_book(
        ::Books::BookAuthor.where(book_id: ranked_scope.select(:item_id)).order(:position, :id).pluck(:book_id, :author_id)
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
