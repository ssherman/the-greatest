module Books
  # Raw params -> validated canon settings.
  #
  # Mirrors Books::FilterParams: an unroutable value raises RecordNotFound
  # rather than falling back to a default, so a hand-edited URL 404s instead of
  # quietly serving a different canon under an address that promised another.
  #
  # The route constraints already reject these values. This is the defensive
  # half, and the only thing standing between a future-loosened constraint and
  # a page that lies about what it is showing.
  class GlobalCanonParams
    TOTALS = [50, 100, 150, 200, 250].freeze
    PERCENTAGES = (0..100)
    COUNTRY_CAPS = (1..10)
    MAX_EXCLUDED_GENRES = 6

    DEFAULT_TOTAL = 150
    DEFAULT_PERCENTAGE = 20
    DEFAULT_COUNTRY_CAP = 3

    INTEGER_FORMAT = /\A\d+\z/

    # Constants inside this block resolve against the lexical scope where the
    # block is written -- i.e. Books::GlobalCanonParams -- not against the
    # anonymous Struct class.
    Settings = Struct.new(
      :total_books, :nonfiction_percentage, :max_books_per_country, :excluded_genres,
      keyword_init: true
    ) do
      def default?
        total_books == DEFAULT_TOTAL &&
          nonfiction_percentage == DEFAULT_PERCENTAGE &&
          max_books_per_country == DEFAULT_COUNTRY_CAP &&
          excluded_genres.empty?
      end
    end

    def self.call(params)
      new(params).call
    end

    def initialize(params)
      @params = params
    end

    def call
      Settings.new(
        total_books: integer(@params[:total_books], DEFAULT_TOTAL) { |v| TOTALS.include?(v) },
        nonfiction_percentage: integer(@params[:nonfiction_percentage], DEFAULT_PERCENTAGE) { |v| PERCENTAGES.cover?(v) },
        max_books_per_country: integer(@params[:max_books_per_country], DEFAULT_COUNTRY_CAP) { |v| COUNTRY_CAPS.cover?(v) },
        excluded_genres: genres(@params[:excluded_genres])
      )
    end

    private

    # Accepts BOTH shapes the two entry points produce: a comma-joined string
    # from the path segment, and an array from the picker's `name="...[]"`
    # hidden inputs. Resolution semantics match Books::FilterParams#resolve --
    # a count mismatch 404s rather than silently dropping a slug, because a URL
    # promising two exclusions must not quietly apply one.
    #
    # Genres only. A subject or setting slug 404s rather than filtering, so the
    # URL space stays exactly what the picker can produce.
    def genres(raw)
      slugs = Array(raw).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?).uniq
      return [] if slugs.empty?
      raise ActiveRecord::RecordNotFound if slugs.size > MAX_EXCLUDED_GENRES

      records = ::Books::Category.active.where(category_type: :genre, slug: slugs).sort_by(&:slug)
      raise ActiveRecord::RecordNotFound if records.size != slugs.size

      records
    end

    def integer(raw, default)
      return default if raw.blank?
      raise ActiveRecord::RecordNotFound unless raw.to_s.match?(INTEGER_FORMAT)

      value = raw.to_i
      raise ActiveRecord::RecordNotFound unless yield(value)

      value
    end
  end
end
