# frozen_string_literal: true

module Services
  module Books
    module Identifiers
      # An admin adding or removing one identifier on a book (work) or an
      # author, through the admin API. A value is normalised and checked
      # where its form is cheap to check (Wikidata, VIAF, ISBN, ISNI), and
      # stored with source `admin`, which the author resolvers treat as
      # authoritative (ResolveWikidata/ResolveViaf#held_stage). So an author
      # holds one Wikidata id and one VIAF id at a time (remove the old one
      # first), and never one a person rejected for that author. Adding or
      # removing either starts a forced enrichment re-run, so the author's
      # facts follow the link. Adding a Wikidata/VIAF id the author already
      # holds from another source promotes that row to `admin` (and re-runs),
      # so it becomes authoritative. Book identifiers trigger nothing.
      #
      # Failures carry data[:code]: :invalid (bad type or value) or
      # :conflict (the author's state refuses it).
      class AdminWrite
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        # The types the admin API reads (every books_* type), and the ones it
        # may write on a book or an author.
        IDENTIFIER_TYPES = ::Identifier.identifier_types.keys.grep(/\Abooks_/).freeze
        BOOK_TYPES = IDENTIFIER_TYPES.grep(/\Abooks_work_/).freeze
        AUTHOR_TYPES = IDENTIFIER_TYPES.grep(/\Abooks_author_/).freeze
        VALUE_LIMIT = 255

        # Held one at a time by an author; adding or removing one re-runs enrichment.
        AUTHOR_LINK_TYPES = %w[books_author_wikidata_qid books_author_viaf].freeze
        WIKIDATA_TYPES = %w[books_work_wikidata_qid books_author_wikidata_qid].freeze
        # Bare Open Library keys as the importers store them ("OL20600W").
        OPEN_LIBRARY_SUFFIXES = {"books_work_openlibrary_id" => "W", "books_author_openlibrary_id" => "A"}.freeze
        INITIATED_BY = "admin_identifier"

        def self.add(record:, identifier_type:, value:)
          new(record).add(identifier_type.to_s, value)
        end

        def self.remove(record:, identifier:)
          new(record).remove(identifier)
        end

        def self.types_for(record)
          record.is_a?(::Books::Author) ? AUTHOR_TYPES : BOOK_TYPES
        end

        def initialize(record)
          @record = record
        end

        def add(type, raw)
          allowed = self.class.types_for(@record)
          unless allowed.include?(type)
            return failure(:invalid, "identifier_type must be one of #{allowed.join(", ")}")
          end

          value, error = normalize(type, raw.to_s)
          return failure(:invalid, error) if error

          existing = @record.identifiers.find_by(identifier_type: type, value: value)
          return keep_or_promote(existing) if existing

          refusal = author_refusal(type, value)
          return failure(:conflict, refusal) if refusal

          identifier = ::ActiveRecord::Base.transaction do
            row = @record.identifiers.create!(identifier_type: type, value: value, source: :admin)
            rerun_enrichment(type)
            row
          end
          added(identifier, created: true)
        rescue ::ActiveRecord::RecordNotUnique
          keep_or_promote(@record.identifiers.find_by!(identifier_type: type, value: value))
        end

        def remove(identifier)
          ::ActiveRecord::Base.transaction do
            identifier.destroy!
            rerun_enrichment(identifier.identifier_type)
          end
          Result.new(success?: true, data: {identifier: identifier}, errors: [])
        end

        private

        # An author's Wikidata/VIAF row from another source becomes `admin`,
        # so the resolvers treat it as authoritative, and enrichment re-runs.
        # Anything else already held is left as it is.
        def keep_or_promote(existing)
          return added(existing, created: false) if existing.source_admin? || !author_link?(existing.identifier_type)

          ::ActiveRecord::Base.transaction do
            existing.update!(source: :admin)
            rerun_enrichment(existing.identifier_type)
          end
          added(existing, created: false, promoted: true)
        end

        def author_link?(type) = @record.is_a?(::Books::Author) && AUTHOR_LINK_TYPES.include?(type)

        # [value, nil] or [nil, error].
        def normalize(type, raw)
          if WIKIDATA_TYPES.include?(type)
            value = raw.strip
            return [nil, "#{type} must be Q followed by digits, e.g. Q7243"] unless value.match?(/\AQ\d+\z/i)
            [value.upcase, nil]
          elsif type == "books_author_viaf"
            value = raw.strip
            return [nil, "#{type} must be digits only, e.g. 96987389"] unless value.match?(/\A\d+\z/)
            [value, nil]
          elsif type.end_with?("_isbn13")
            isbn(raw, /\A\d{13}\z/, :isbn13, "#{type} must be 13 digits with a valid ISBN-13 check digit (hyphens and spaces are ignored)")
          elsif type.end_with?("_isbn10")
            isbn(raw, /\A\d{9}[\dX]\z/, :isbn10, "#{type} must be 9 digits and a check digit 0-9 or X, a valid ISBN-10 (hyphens and spaces are ignored)")
          elsif OPEN_LIBRARY_SUFFIXES.key?(type)
            suffix = OPEN_LIBRARY_SUFFIXES.fetch(type)
            value = raw.strip.upcase
            return [nil, "#{type} must be OL, digits and #{suffix}, e.g. OL26783#{suffix}"] unless value.match?(/\AOL\d+#{suffix}\z/)
            [value, nil]
          elsif type == "books_author_isni"
            value = raw.delete(" \t").upcase
            return [nil, "#{type} must be 16 characters, digits or X (spaces are ignored)"] unless value.match?(/\A[0-9X]{16}\z/)
            [value, nil]
          else
            value = raw.strip
            return [nil, "value must not be blank"] if value.empty?
            return [nil, "value must be at most #{VALUE_LIMIT} characters"] if value.length > VALUE_LIMIT
            [value, nil]
          end
        end

        def isbn(raw, form, field, error)
          value = raw.gsub(/[\s-]/, "").upcase
          return [nil, error] unless value.match?(form) && ::Books::Isbn.normalize(value)&.public_send(field) == value

          [value, nil]
        end

        def author_refusal(type, value)
          return nil unless author_link?(type)

          if ::Services::Books::Authors::RejectedRecords.new(@record).identifier?(type, value)
            return "#{value} was rejected as this author's record and cannot be added back"
          end

          held = @record.identifiers.where(identifier_type: type).pluck(:value)
          "The author already holds #{type} #{held.join(", ")}: remove #{held.first} first" if held.any?
        end

        def rerun_enrichment(type)
          return unless author_link?(type)

          ::Workflows::Books::AuthorEnrichment.start(@record, initiated_by: INITIATED_BY, options: {refresh: true}, supersede: true)
        end

        def added(identifier, created:, promoted: false)
          Result.new(success?: true, data: {identifier: identifier, created: created, promoted: promoted}, errors: [])
        end

        def failure(code, message)
          Result.new(success?: false, data: {code: code}, errors: [message])
        end
      end
    end
  end
end
