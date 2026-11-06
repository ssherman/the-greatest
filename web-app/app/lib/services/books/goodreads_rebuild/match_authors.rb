# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # For one book, which of the export's author names are the book's own
      # current authors? "Kurt Vonnegut" and "Kurt Vonnegut Jr." are the same
      # person, "Roy Heath" and "Chip Heath" are not, and names alone prove
      # neither, so what the name key (Services::Text::PersonNameKey, the
      # finder's own, initials folded) does not settle is asked of the AI,
      # which sees each current author's other books. Only a "high" answer
      # links. data[:links] is {export name => author id}; data[:all_matched]
      # is true when every export name is linked. A failed AI call fails the
      # result, so the caller can try the book again later.
      class MatchAuthors
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(book:, facts:, task_class: ::Services::Ai::Tasks::Books::MatchExportAuthorsTask)
          new(book: book, facts: facts, task_class: task_class).call
        end

        def initialize(book:, facts:, task_class:)
          @book = book
          @facts = facts
          @task_class = task_class
        end

        def call
          names = Array(@facts.author_names).compact_blank
          authors = @book.authors.reload.to_a
          links = direct_links(names, authors)
          rest = names - links.keys

          if rest.any? && authors.any?
            result = @task_class.new(title: @facts.full_title, year: @facts.year, export_names: rest, authors: authors,
              book_id: @book.id, parent: @book).call
            return Result.new(success?: false, data: {}, errors: [result.error]) unless result.success?

            links.merge!(ai_links(result.data[:matches], authors, links.values))
          end

          Result.new(success?: true, data: {links: links, all_matched: names.any? && names.all? { |name| links.key?(name) }}, errors: [])
        end

        private

        def direct_links(names, authors)
          keys = authors.to_h { |author| [author.id, ::Services::Text::PersonNameKey.all([author.name, *Array(author.alternate_names)])] }
          names.each_with_object({}) do |name, links|
            key = ::Services::Text::PersonNameKey.call(name)
            author = authors.find { |candidate| keys[candidate.id].include?(key) }
            links[name] = author.id if key && author
          end
        end

        def ai_links(matches, authors, taken)
          highs = Array(matches).select { |match| match[:confidence] == "high" && match[:author_number] }.group_by { |match| match[:export_name] }
          highs.each_with_object({}) do |(name, answers), links|
            # Two different authors for one name is an ambiguous answer: link neither.
            next if answers.map { |answer| answer[:author_number] }.uniq.size > 1

            author = authors[answers.first[:author_number] - 1]
            next if author.nil? || taken.include?(author.id)

            taken << author.id
            links[name] = author.id
          end
        end
      end
    end
  end
end
