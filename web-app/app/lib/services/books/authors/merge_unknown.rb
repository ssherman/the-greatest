# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Merges every placeholder author (Anonymous, Unknown Author, a second
      # "Unknown", ...) into the canonical Unknown author through the normal
      # author merger, so redirects, list items, reviews and the legacy sync
      # follow it as they follow an admin merge. Idempotent: a rerun finds
      # nothing left. It repeats after each legacy sync, which can bring new
      # placeholder authors straight from legacy without the import finder.
      #
      # The descriptions those authors carry (mostly AI text: "Anonymous is a
      # placeholder name used when...") are dropped once their merge
      # succeeds, whatever their source, so the survivor does not collect a
      # copy from each. A failed merge keeps them.
      class MergeUnknown
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(apply: false)
          new(apply: apply).call
        end

        def initialize(apply:)
          @apply = apply
        end

        def call
          target = UnknownAuthor.canonical
          return Result.new(success?: false, data: nil, errors: ["no author named \"#{UnknownAuthor::CANONICAL_NAME}\""]) unless target

          sources = UnknownAuthor.placeholders.where.not(id: target.id).order(:id).to_a
          data = {
            target_id: target.id, target_books: target.book_authors.count,
            sources: sources.map { |author| {id: author.id, name: author.name, books: author.book_authors.count} },
            merged: 0, failed: []
          }
          return Result.new(success?: true, data: data, errors: []) unless @apply

          begin
            sources.each do |source|
              description_ids = source.descriptions.pluck(:id)
              result = ::Books::Author::Merger.call(source: source, target: target, defer_rankings: true)
              if result.success?
                data[:merged] += 1
                ::Description.where(id: description_ids, describable_type: "Books::Author", describable_id: target.id).find_each(&:destroy!)
              else
                data[:failed] << {id: source.id, errors: result.errors}
              end
            end
          ensure
            # Even when a later step raises: the merges already done each
            # deferred their refresh.
            refresh_author_rankings if data[:merged].positive?
          end

          Result.new(success?: true, data: data, errors: [])
        end

        private

        # Each merge deferred its refresh; one request covers them all.
        def refresh_author_rankings
          authors = ::Books::Authors::RankingConfiguration.default_primary
          ::Services::RankingConfigurations::RequestRefresh.call(config: authors, delay: 5.minutes) if authors
        end
      end
    end
  end
end
