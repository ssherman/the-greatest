# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Our side of an author, as matching evidence (spec §5.1, §5.2): its
      # names, its titles (the author's books, ranked first under the default
      # primary configuration, each followed by its alternate titles), and the
      # one line SelectExternalRecordTask is given about it.
      class AuthorProfile
        TITLE_LIMIT = 50

        def self.lifespan(birth, death)
          return nil if birth.nil? && death.nil?

          "#{birth || "?"}–#{death}"
        end

        def initialize(author)
          @author = author
        end

        def names
          ([author.name] + Array(author.alternate_names)).map { |name| name.to_s.squish }.reject(&:blank?)
        end

        def titles
          @titles ||= ranked_books_scope.limit(TITLE_LIMIT).pluck(:title, :alternate_titles)
            .flat_map { |title, alternates| [title, *Array(alternates)] }
            .compact_blank.uniq.first(TITLE_LIMIT)
        end

        # Our books by this author, ranked first: [[title, first_published_year], ...].
        def ranked_books(limit)
          ranked_books_scope.limit(limit).pluck(:title, :first_published_year)
        end

        # The year the author's most recent book of ours first appeared, or nil.
        def latest_published_year
          written_books.maximum("books_books.first_published_year")
        end

        def line
          parts = [author.name]
          alternates = Array(author.alternate_names).first(5)
          parts << "also known as #{alternates.join(", ")}" if alternates.any?
          span = self.class.lifespan(author.birth_year, author.death_year)
          parts << span if span
          parts << "wrote: #{titles.first(10).join("; ")}" if titles.any?
          countries = author.countries.map(&:name)
          parts << "countries: #{countries.join(", ")}" if countries.any?
          parts.join(" | ")
        end

        private

        attr_reader :author

        # The books the author wrote, ranked first under the default primary
        # configuration, then by id. A book they only edited is not theirs,
        # the same rule as Books::TopBooksForAuthorsQuery.
        def ranked_books_scope
          configuration = ::Books::RankingConfiguration.default_primary
          return written_books.order("books_books.id") unless configuration

          join = ActiveRecord::Base.sanitize_sql_array([
            "LEFT JOIN ranked_items ON ranked_items.item_type = 'Books::Book' " \
            "AND ranked_items.item_id = books_books.id AND ranked_items.ranking_configuration_id = ?",
            configuration.id
          ])
          written_books.joins(join).order(Arel.sql("ranked_items.rank ASC NULLS LAST"), "books_books.id")
        end

        def written_books
          author.books.where(books_book_authors: {role: ::Books::BookAuthor.roles[:author]})
        end
      end
    end
  end
end
