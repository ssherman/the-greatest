module Books
  class TopBooksForAuthorsQuery
    def self.call(author_ids:, ranking_configuration:, limit: 5)
      return {} if author_ids.blank? || ranking_configuration.nil?

      sql = <<~SQL
        SELECT author_id, book_id FROM (
          SELECT ba.author_id AS author_id,
                 ri.item_id AS book_id,
                 ROW_NUMBER() OVER (PARTITION BY ba.author_id ORDER BY ri.rank ASC) AS position
          FROM ranked_items ri
          JOIN books_book_authors ba ON ba.book_id = ri.item_id
          WHERE ri.item_type = 'Books::Book'
            AND ri.ranking_configuration_id = :rc_id
            AND ri.rank IS NOT NULL
            AND ba.role = :role
            AND ba.author_id IN (:author_ids)
        ) ranked
        WHERE position <= :limit
        ORDER BY author_id, position
      SQL

      rows = ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array([
          sql,
          {
            rc_id: ranking_configuration.id,
            role: ::Books::BookAuthor.roles[:author],
            author_ids: author_ids,
            limit: limit
          }
        ])
      ).to_a

      books = ::Books::Book
        .where(id: rows.map { |row| row["book_id"] }.uniq)
        .includes(primary_image: {file_attachment: :blob})
        .index_by(&:id)

      rows.each_with_object({}) do |row, grouped|
        book = books[row["book_id"]]
        next unless book

        (grouped[row["author_id"]] ||= []) << book
      end
    end
  end
end
