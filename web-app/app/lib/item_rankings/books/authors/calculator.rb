# frozen_string_literal: true

module ItemRankings
  module Books
    module Authors
      class Calculator < ItemRankings::Calculator
        def call
          source = ::Books::RankingConfiguration.default_primary

          if source.nil?
            return Result.new(
              success?: false,
              data: nil,
              errors: ["No primary Books::RankingConfiguration to derive author scores from"]
            )
          end

          ranking_data = author_scores(source)
          update_ranked_items(ranking_data)

          Result.new(success?: true, data: ranking_data, errors: [])
        rescue => error
          Result.new(success?: false, data: nil, errors: [error.message])
        end

        protected

        def list_type
          raise NotImplementedError, "Authors are derived from ranked books, not ranked from lists"
        end

        def item_type
          "Books::Author"
        end

        private

        def author_scores(source)
          rows = ActiveRecord::Base.connection.select_all(aggregation_sql(source.id))

          rows.filter_map { |row|
            score = ScoreFormula.call(
              book_count: row["book_count"],
              total_score: row["total_score"]
            )
            {id: row["author_id"], total_score: score} if score > 0
          }.sort_by { |author| -author[:total_score] }
        end

        def aggregation_sql(source_id)
          <<~SQL
            SELECT ba.author_id AS author_id,
                   COUNT(*) AS book_count,
                   SUM(ri.score) AS total_score
            FROM ranked_items ri
            JOIN books_book_authors ba ON ba.book_id = ri.item_id
            JOIN books_authors a ON a.id = ba.author_id
            WHERE ri.item_type = 'Books::Book'
              AND ri.ranking_configuration_id = #{source_id.to_i}
              AND ri.score > 0
              AND ba.role = #{::Books::BookAuthor.roles[:author].to_i}
              AND a.exclude_from_rankings = FALSE
            GROUP BY ba.author_id
          SQL
        end
      end
    end
  end
end
