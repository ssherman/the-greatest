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
          @titles ||= begin
            configuration = ::Books::RankingConfiguration.default_primary
            scope = author.books
            scope = if configuration
              join = ActiveRecord::Base.sanitize_sql_array([
                "LEFT JOIN ranked_items ON ranked_items.item_type = 'Books::Book' " \
                "AND ranked_items.item_id = books_books.id AND ranked_items.ranking_configuration_id = ?",
                configuration.id
              ])
              scope.joins(join).order(Arel.sql("ranked_items.rank ASC NULLS LAST"), "books_books.id")
            else
              scope.order("books_books.id")
            end
            scope.limit(TITLE_LIMIT).pluck(:title, :alternate_titles)
              .flat_map { |title, alternates| [title, *Array(alternates)] }
              .compact_blank.uniq.first(TITLE_LIMIT)
          end
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
      end
    end
  end
end
