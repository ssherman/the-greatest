# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 1, passes 1 and 2: which Open Library work, if any, this
      # book is. Raises the client's errors (a 4xx on an identifier is no
      # hit); Run retries them.
      class Lookup
        # confirm_only: Open Library abstained, but its top candidate is a key the
        # book already holds and agrees with it. Nothing is to be changed.
        # ol_pick: the key Open Library accepted or ranked top, even when it failed
        # our check (work is then nil). Never removed from the book.
        Answer = Data.define(:work, :lookup, :duplicates, :redirect_sources, :source_version, :confirm_only, :ol_pick) do
          def initialize(work:, lookup:, duplicates:, redirect_sources:, source_version:, confirm_only: false, ol_pick: nil)
            super
          end
        end

        FAST_TYPES = {
          "books_work_isbn13" => "isbn13",
          "books_work_isbn10" => "isbn10",
          "books_work_goodreads_id" => "goodreads"
        }.freeze
        # Enough lookups to show whether a book's identifiers agree.
        MAX_FAST_LOOKUPS = 5
        MAX_WORLDCAT_LOOKUPS = 5
        NO_HIT_STATUSES = [400, 422].freeze
        RESOLVE_IDENTIFIERS_PER_TYPE = 3

        def self.call(book:, client:)
          new(book, client).call
        end

        def initialize(book, client)
          @book = book
          @client = client
        end

        def call
          fast || full
        end

        private

        def identifiers
          @identifiers ||= @book.identifiers.where(identifier_type: FAST_TYPES.keys).order(:id).pluck(:identifier_type, :value)
        end

        def values(type) = identifiers.select { |held, _| held == type }.map(&:last)

        def stored_keys
          @book.identifiers.where(identifier_type: :books_work_openlibrary_id).order(:id).pluck(:value)
        end

        def fast
          return nil if identifiers.empty?

          hits = fast_hits
          keys = hits.map(&:work_key).compact.uniq
          return nil unless keys.size == 1

          work = @client.works_batch(keys)[keys.first]
          return nil unless work && Check.verified?(@book, work, @client)

          Answer.new(work: work, lookup: :identifiers, duplicates: [], redirect_sources: [], source_version: work.source_version)
        end

        # One thread per lookup (the client and its breaker are safe for
        # concurrent requests; the threads touch no database connection).
        # Joined in order; the first error, in lookup order, is raised.
        def fast_hits
          lookup_hits(identifiers.first(MAX_FAST_LOOKUPS).map { |type, value| [FAST_TYPES.fetch(type), value] })
        end

        def lookup_hits(lookups)
          threads = lookups.map do |type, value|
            Thread.new do
              hits_for(type, value)
            rescue => e
              e
            end
          end
          results = threads.map(&:value)
          error = results.find { |result| result.is_a?(Exception) }
          raise error if error

          results.flatten
        end

        def hits_for(type, value)
          @client.identifier(type, value)
        rescue ::Books::OpenLibrary::Exceptions::ClientError => e
          # 404 (unknown), 400/422 (a value the service cannot normalise): no hit.
          # Anything else (401, 403, 429...) is about us, not the book.
          raise unless e.is_a?(::Books::OpenLibrary::Exceptions::NotFoundError) || NO_HIT_STATUSES.include?(e.status_code)

          []
        end

        def full
          resolution = @client.resolve(
            title: @book.title.to_s,
            author_names: @book.authors.map(&:name),
            year: @book.first_published_year,
            isbn13: values("books_work_isbn13").first(RESOLVE_IDENTIFIERS_PER_TYPE),
            isbn10: values("books_work_isbn10").first(RESOLVE_IDENTIFIERS_PER_TYPE),
            goodreads_id: values("books_work_goodreads_id").first(RESOLVE_IDENTIFIERS_PER_TYPE),
            existing_ol_key: stored_keys.first
          )
          accepted = resolution.accepted
          work = accepted&.record
          if work && Check.verified?(@book, work, @client)
            return Answer.new(work: work, lookup: :resolve, duplicates: resolution.decision.duplicates.uniq - [work.key],
              redirect_sources: Array(accepted.redirect_sources), source_version: resolution.source_version)
          end

          held = confirmable_stored_key(resolution)
          chance = second_chance(resolution) unless held
          return chance if chance

          Answer.new(work: held, lookup: :resolve, duplicates: [], redirect_sources: [],
            source_version: resolution.source_version, confirm_only: !held.nil?,
            ol_pick: accepted&.work_key || resolution.candidates.first&.work_key)
        end

        # The held keys (spec step 4) first, then Open Library's own candidates
        # (steps 2-3), then the WorldCat-confirmed ISBNs (step 5), all behind the
        # same guards and each held to our check. Returns an Answer or nil. The
        # held key goes first because a candidate passing the same check is no
        # reason to move: in the dev rehearsal, One Hundred Years of Solitude
        # traded its 208-edition work for a 2-edition English stub.
        def second_chance(resolution)
          return nil if guarded?(resolution)

          usable = resolution.candidates.select { |candidate| candidate.record && candidate.conflicting_features.empty? }
          conflicted = conflicted_keys(resolution)
          held_key(resolution, conflicted) || resolve_candidate(resolution, usable) ||
            exact_title(resolution, usable) || worldcat_isbns(resolution, conflicted)
        end

        # The matcher's guards: a reject, an identifier conflict, a tripped volume guard.
        def guarded?(resolution)
          resolution.decision.verdict == "reject" ||
            resolution.decision.reason.to_s.start_with?("identifier conflict") ||
            !resolution.volume_guards_tripped.empty?
        end

        def conflicted_keys(resolution)
          resolution.candidates.reject { |candidate| candidate.conflicting_features.empty? }.map(&:work_key)
        end

        # A duplicate key is an identity claim (importers find books by it), so
        # only a work whose full title, subtitle included, is the book's own
        # title. Alternate titles do not count, as in HarvestEditions: legacy
        # data gives some volumes their series' name.
        def exact_title?(work)
          ours = Check.title_key(@book.title)
          ours.present? && Check.their_title_keys(work).first == ours
        end

        # Spec step 4: a legacy key the book holds whose live work passes our check.
        def held_key(resolution, conflicted)
          keys = stored_keys.uniq - conflicted
          return nil if keys.empty?

          # A held key that is also a candidate already has its record.
          works = resolution.candidates.select { |candidate| candidate.record && keys.include?(candidate.work_key) }.to_h { |candidate| [candidate.work_key, candidate.record] }
          missing = keys - works.keys
          works = works.merge(@client.works_batch(missing)) if missing.any?
          passing = keys.filter_map { |key| works[key] }.select { |work| Check.verified?(@book, work, @client) }
          return nil if passing.empty?

          ours = Check.title_key(@book.title)
          chosen = passing.find { |work| ours && Check.their_title_keys(work).first == ours } || passing.first
          Answer.new(work: chosen, lookup: :held_key, duplicates: passing.select { |work| exact_title?(work) }.map(&:key) - [chosen.key], redirect_sources: [],
            source_version: resolution.source_version, ol_pick: resolution.candidates.first&.work_key)
        end

        # Spec step 5: the book's WorldCat-confirmed ISBNs, looked up in Open
        # Library as ISBN-13s; the work most of them lead to, if it passes.
        def worldcat_isbns(resolution, conflicted)
          isbns = @book.identifiers.where(identifier_type: [:books_work_isbn13, :books_work_isbn10], source: :worldcat)
            .order(:id).pluck(:value).filter_map { |value| ::Books::Isbn.normalize(value)&.isbn13 }.uniq
          return nil if isbns.empty?

          tally = lookup_hits(isbns.first(MAX_WORLDCAT_LOOKUPS).map { |isbn| ["isbn13", isbn] }).filter_map(&:work_key).tally
          return nil if tally.empty?

          keys = (tally.keys - conflicted).each_with_index.sort_by { |key, index| [-tally[key], index] }.map(&:first)
          return nil if keys.empty?

          works = @client.works_batch(keys)
          passing = keys.filter_map { |key| works[key] }.select { |work| Check.verified?(@book, work, @client) }
          return nil if passing.empty?

          Answer.new(work: passing.first, lookup: :worldcat_isbns, duplicates: passing.drop(1).select { |work| exact_title?(work) }.map(&:key), redirect_sources: [],
            source_version: resolution.source_version, ol_pick: resolution.candidates.first&.work_key)
        end

        def resolve_candidate(resolution, usable)
          passing = usable.reject(&:reject?).select { |candidate| Check.verified?(@book, candidate.record, @client) }
          return nil if passing.empty?

          wanted = ([@book.title] + Array(@book.alternate_titles)).filter_map { |title| Check.title_key(title) }
          chosen = passing.find { |candidate| wanted.include?(Check.their_title_keys(candidate.record).first) } || passing.first
          others = (passing - [chosen]).map(&:record).select { |work| exact_title?(work) }.map(&:key)
          second_chance_answer(resolution, :resolve_candidate, chosen, others)
        end

        # A reject-banded candidate whose full title is exactly ours.
        def exact_title(resolution, usable)
          ours = Check.title_key(@book.title)
          return nil if ours.nil?

          chosen = usable.select(&:reject?).sort_by { |candidate| -candidate.score.to_f }.find do |candidate|
            Check.their_title_keys(candidate.record).first == ours && Check.verified?(@book, candidate.record, @client)
          end
          chosen && second_chance_answer(resolution, :exact_title, chosen, [])
        end

        # A candidate pick is never a key the book holds: held_key runs first and
        # takes any held key that passes.
        def second_chance_answer(resolution, lookup, chosen, others)
          Answer.new(work: chosen.record, lookup: lookup, duplicates: others.uniq - [chosen.work_key],
            redirect_sources: Array(chosen.redirect_sources), source_version: resolution.source_version,
            ol_pick: resolution.candidates.first&.work_key)
        end

        # Not an accept, but the top candidate is a key we hold and its record
        # agrees with the book: famous books with many near-identical Open
        # Library records abstain on margin even then. Behind the same guards
        # as the second chance: confirming trusts the key.
        def confirmable_stored_key(resolution)
          return nil if resolution.accept? || guarded?(resolution)

          top = resolution.candidates.first
          return nil unless top&.record && top.conflicting_features.empty? && stored_keys.include?(top.work_key)

          top.record if Check.verified?(@book, top.record, @client)
        end
      end
    end
  end
end
