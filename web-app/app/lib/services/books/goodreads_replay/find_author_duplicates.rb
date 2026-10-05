# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Goodreads import spec §12.5, authors. Covers every author whose
      # normalized name another author shares, import-created or not: the legacy
      # add-book modal made authors with find_or_create_by!(name:) too.
      #
      # The normalized name is lowercase with everything but letters and digits
      # removed, so "J.D. Vance" and "J. D. Vance" are one group. Each group is
      # one fast AI call that clusters it into people (GroupSameAuthorsTask).
      # Each clustered pair becomes a merge_authors verdict, merging into the
      # author ranked first, then the one with the most books, then the oldest.
      #
      # A pair is approved on its own only when all three hold:
      # - the AI is highly confident;
      # - no birth or death year conflicts (both present and different);
      # - no external identifier conflicts (both hold one of a kind, and they
      #   share none).
      # The rest are proposed. A pair an admin marked not a duplicate is skipped.
      # Records findings only; merges nothing.
      class FindAuthorDuplicates
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        KEY_SQL = "regexp_replace(lower(books_authors.name), '[^[:alnum:]]+', '', 'g')"
        IDENTIFIER_TYPES = %w[books_author_openlibrary_id books_author_wikidata_qid books_author_viaf].freeze

        def self.call(task_class: ::Services::Ai::Tasks::Books::GroupSameAuthorsTask)
          new(task_class: task_class).call
        end

        def initialize(task_class:)
          @task_class = task_class
          @ai_calls = 0
        end

        def call
          tally = Hash.new(0)
          group_keys.each { |key| tally[check(key)] += 1 }
          Result.new(success?: true, data: {tally: tally.to_h, ai_calls: @ai_calls}, errors: [])
        end

        private

        def group_keys
          ::Books::Author.where.not(Arel.sql("#{KEY_SQL} = ''")).group(Arel.sql(KEY_SQL)).having("count(*) > 1")
            .order(Arel.sql(KEY_SQL)).pluck(Arel.sql(KEY_SQL))
        end

        def check(key)
          authors = ::Books::Author.where("#{KEY_SQL} = ?", key).includes(:identifiers).order(:id).to_a
          return :too_large if authors.size > Rails.configuration.x.goodreads_replay.max_author_group

          @ai_calls += 1
          result = @task_class.new(author_lines: authors.map { |author| line(author) }, parent: authors.first).call
          return :ai_failed unless result.success?

          result.data[:groups].each { |group| record(group.fetch(:members).map { |n| authors[n - 1] }, group.fetch(:confidence), result.ai_chat) }
          :checked
        end

        def line(author)
          parts = [::Services::Books::Authors::AuthorProfile.new(author).line]
          parts << "kind: #{author.kind}" if author.kind.present? && author.kind != "person"
          ids = author.identifiers.select { |i| IDENTIFIER_TYPES.include?(i.identifier_type) }
            .map { |i| "#{i.identifier_type.delete_prefix("books_author_")} #{i.value}" }
          parts << "ids: #{ids.join(", ")}" if ids.any?
          parts.join(" | ")
        end

        def record(members, confidence, ai_chat)
          target = preferred(members)
          (members - [target]).each do |source|
            next if ::DuplicateCandidate.not_duplicate?(item_type: "Books::Author", ids: [source.id, target.id])

            conflicts = conflicts(source, target)
            RecordVerdict.call(
              kind: :merge_authors, subject_key: "authors:#{[source.id, target.id].minmax.join(":")}",
              payload: {source_id: source.id, target_id: target.id, names: [source.name, target.name], conflicts: conflicts},
              decided_by: :ai, confidence: confidence, ai_chat_id: ai_chat&.id,
              reason: conflicts.empty? ? "same person, by the AI's check of both authors' books" : "the AI says same person, but #{conflicts.join("; ")}",
              auto: conflicts.empty? && confidence == "high"
            )
          end
        end

        def preferred(members)
          ids = members.map(&:id)
          configuration = ::Books::Authors::RankingConfiguration.default_primary
          ranks = configuration ? ::RankedItem.where(ranking_configuration_id: configuration.id, item_type: "Books::Author", item_id: ids).pluck(:item_id, :rank).to_h : {}
          books = ::Books::BookAuthor.where(author_id: ids).group(:author_id).count
          members.min_by { |author| [ranks.key?(author.id) ? 0 : 1, ranks[author.id].to_i, -books.fetch(author.id, 0), author.id] }
        end

        def conflicts(a, b)
          years = %i[birth_year death_year].filter_map do |field|
            "#{field.to_s.tr("_", " ")}s differ (#{a[field]} vs #{b[field]})" if a[field] && b[field] && a[field] != b[field]
          end
          identifiers = IDENTIFIER_TYPES.filter_map do |type|
            held_a = values(a, type)
            held_b = values(b, type)
            "different #{type}" if held_a.any? && held_b.any? && (held_a & held_b).empty?
          end
          years + identifiers
        end

        def values(author, type)
          author.identifiers.select { |identifier| identifier.identifier_type == type }.map(&:value)
        end
      end
    end
  end
end
