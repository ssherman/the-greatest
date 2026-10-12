# frozen_string_literal: true

module Books
  module WorldCat
    Record = Data.define(
      :oclc, :title, :subtitle, :creator, :contributors, :year, :publisher, :publication_place,
      :cataloging_language, :specific_format, :edition_statement, :genre, :subjects, :isbn13s,
      :merged_oclc, :other_format_oclc, :total_editions, :summary, :holding_count, :holdings_editions,
      :redirected_from
    ) do
      def self.from_hash(hash)
        holdings = hash["holdings"] || {}
        new(
          oclc: hash["oclc"], title: hash["title"], subtitle: hash["subtitle"], creator: hash["creator"],
          contributors: hash["contributors"] || [], year: hash["year"], publisher: hash["publisher"],
          publication_place: hash["publication_place"], cataloging_language: hash["cataloging_language"],
          specific_format: hash["specific_format"], edition_statement: hash["edition_statement"],
          genre: hash["genre"], subjects: hash["subjects"] || [], isbn13s: hash["isbn13s"] || [],
          merged_oclc: hash["merged_oclc"] || [], other_format_oclc: hash["other_format_oclc"] || [],
          total_editions: hash["total_editions"], summary: hash["summary"],
          holding_count: holdings["total_holding_count"], holdings_editions: holdings["total_editions"],
          redirected_from: hash["redirected_from"]
        )
      end
    end
  end
end
