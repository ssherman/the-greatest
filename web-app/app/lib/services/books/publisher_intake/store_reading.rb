# frozen_string_literal: true

require "zlib"

module Services
  module Books
    module PublisherIntake
      # Stores the outcome of reading one listing's page (publisher intake design
      # §4): the listing's state, the gzipped page, and for a found page the
      # title it describes. Pacing is the job's; this touches the database and
      # Active Storage, never the network, and writes nothing to books, editions,
      # authors or identifiers.
      #
      # A listing that was already read (read_at is set, whatever its state: a
      # re-read starts from pending) keeps its stored page, outcome, facts and
      # title through any later attempt that is not a good page: a good page is
      # never replaced by a bad one. Only last_attempt_* moves.
      #
      # reparse: true is for re-reading the page already stored (Reparse): nothing
      # was fetched, so the stored page, last_attempt_*, queued_at and the
      # state of an already-read listing stay as they are. A found reading
      # stores its title and facts (a never-read listing becomes read, with
      # read_at the time its page was fetched); any other outcome only stamps
      # parser_version.
      #
      # data: {outcome:, title:}. outcome is the one that was applied, which is
      # :unparseable when a :found reading had no title or no usable ISBN-13.
      class StoreReading
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        # Reading facts that are plain columns of the title. source always comes
        # from the listing and source_key is handled apart.
        SCALAR_FACTS = %i[title subtitle imprint_name publisher_name language series_name series_position age_range
          description cover_url].freeze
        ARRAY_FACTS = %i[contributors genres].freeze

        def self.call(listing:, reading:, page:, parser_version:, reparse: false)
          new(listing: listing, reading: reading, page: page, parser_version: parser_version, reparse: reparse).call
        end

        def initialize(listing:, reading:, page:, parser_version:, reparse: false)
          @reparse = reparse
          @listing = listing
          @reading = reading
          @page = page
          @parser_version = parser_version
          @now = Time.current
          @was_read = listing.read_at.present?
        end

        def call
          outcome = @reading.outcome.to_sym
          if outcome == :found
            @facts = normalise(@reading.facts || {})
            outcome = :unparseable unless usable?(@facts)
          end

          title = nil
          ::Books::PublisherListing.transaction do
            unless @reparse
              @listing.last_attempt_outcome = outcome
              @listing.last_attempt_at = @now
              @listing.queued_at = nil
            end
            title = @reparse ? apply_reparse(outcome) : apply(outcome)
            @listing.save!
          end
          Result.new(success?: true, data: {outcome: outcome, title: title}, errors: [])
        end

        private

        def apply_reparse(outcome)
          return store_found if outcome == :found

          @listing.parser_version = @parser_version
          nil
        end

        def apply(outcome)
          case outcome
          when :found then store_found
          when :not_found then store_not_found
          when :blocked, :unparseable then store_unusable(outcome)
          when :unavailable then store_unavailable
          end
        end

        def store_found
          title = upsert_title
          if @reparse
            # The page was fetched at last_attempt_at; an already-read listing keeps its read_at and state.
            @listing.assign_attributes(outcome: :found, parser_version: @parser_version, publisher_title: title)
            unless @was_read
              @listing.assign_attributes(state: :read, read_at: @listing.last_attempt_at || @now, attempts: 0)
            end
          else
            @listing.assign_attributes(state: :read, outcome: :found, http_status: @page&.status,
              parser_version: @parser_version, read_at: @now, attempts: 0, publisher_title: title)
            attach_page
          end
          cover_siblings(title)
          title
        end

        def store_not_found
          @listing.assign_attributes(state: :failed, outcome: :not_found, http_status: @page&.status,
            parser_version: @parser_version, attempts: 0)
          nil
        end

        def store_unusable(outcome)
          if @was_read
            @listing.state = :read
          else
            @listing.assign_attributes(outcome: outcome, http_status: @page&.status, parser_version: @parser_version,
              attempts: 0)
            attach_page
          end
          nil
        end

        def store_unavailable
          if @was_read
            @listing.state = :read
          else
            @listing.attempts += 1
            @listing.state = (@listing.attempts >= ::Books::PublisherIntake.settings.fetch_attempts) ? :failed : :pending
          end
          nil
        end

        def normalise(facts)
          formats = Array(facts[:formats]).filter_map do |format|
            isbn = ::Books::PublisherIntake::Isbn.normalize(format[:isbn13])
            format.merge(isbn13: isbn) if isbn
          end
          facts.merge(formats: formats)
        end

        def usable?(facts)
          facts[:title].present? && facts[:formats].any? { |f| f[:isbn13].present? }
        end

        def upsert_title
          isbns = @facts[:formats].map { |f| f[:isbn13] }.uniq
          title = find_title(isbns) || ::Books::PublisherTitle.new(source: @listing.source)
          status, reason = ::Books::PublisherIntake::Hold.call(@facts)

          title.assign_attributes(attributes_for(title))
          title.isbn13s = (title.isbn13s | isbns)
          title.on_sale_on = earliest_on_sale
          title.status = status
          title.hold_reason = reason
          title.first_read_at ||= @now
          title.last_read_at = @now
          title.parser_version = @parser_version
          title.save!
          title
        end

        def attributes_for(title)
          attrs = SCALAR_FACTS.index_with { |key| @facts[key] }
          ARRAY_FACTS.each { |key| attrs[key] = Array(@facts[key]) }
          attrs[:formats] = @facts[:formats].map { |f| f.merge(on_sale_on: date_of(f[:on_sale_on])&.iso8601) }
          attrs[:source_key] = @facts[:source_key] if @facts[:source_key].present?
          attrs
        end

        def find_title(isbns)
          scope = ::Books::PublisherTitle.where(source: @listing.source)
          return scope.find_by(source_key: @facts[:source_key]) if @facts[:source_key].present?

          overlapping = scope.where("isbn13s && ARRAY[?]::varchar[]", isbns).order(:id).to_a
          return overlapping.first if overlapping.size <= 1

          best = overlapping.min_by { |t| [-(t.isbn13s & isbns).size, t.id] }
          Rails.logger.warn("#{self.class.name}: page ISBNs overlap publisher titles #{overlapping.map(&:id).join(" and ")} " \
            "of #{@listing.source}; using #{best.id}")
          best
        end

        def earliest_on_sale
          dates = @facts[:formats].filter_map { |f| date_of(f[:on_sale_on]) }
          dates.min || date_of(@facts[:on_sale_on])
        end

        def date_of(value)
          return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

          Date.iso8601(value.to_s)
        rescue Date::Error
          nil
        end

        # Other formats this page listed: never fetched, they point at the title.
        def cover_siblings(title)
          keys = Array(@reading.sibling_keys).filter_map { |k| ::Books::PublisherIntake::Isbn.normalize(k) || k.presence&.to_s }
          return if keys.empty?

          ::Books::PublisherListing.where(source: @listing.source, external_key: keys, state: %i[baseline pending])
            .where.not(id: @listing.id).find_each do |sibling|
            sibling.update!(state: :covered, publisher_title: title)
          end
        end

        def attach_page
          return unless @page

          @listing.html.attach(io: StringIO.new(Zlib.gzip(@page.html.to_s)), filename: "#{@listing.source}-#{@listing.id}.html.gz",
            content_type: "application/gzip", identify: false, metadata: {analyzed: true})
        end
      end
    end
  end
end
