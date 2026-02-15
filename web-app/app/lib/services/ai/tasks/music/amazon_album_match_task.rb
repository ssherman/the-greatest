# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Music
        class AmazonAlbumMatchTask < ::Services::Ai::Tasks::AmazonProductMatchTask
          private

          def domain_name
            "album"
          end

          def item_description
            album_artists = parent.artists.map(&:name).join(", ")
            lines = [
              "- Title: #{parent.title}",
              "- Artists: #{album_artists}"
            ]
            lines << "- Release Year: #{parent.release_year}" if parent.release_year.present?
            lines.join("\n")
          end

          def match_criteria
            <<~CRITERIA.strip
              - The titles represent the same musical work (allowing for variations in subtitles or editions)
              - The artists match (allowing for variations in name format)
              - The result is the actual album, not merchandise, tribute albums, or covers

              Examples of what IS a match:
              - Different editions of the same album (remastered, deluxe, etc.)
              - Slight variations in title formatting
              - Different formats (CD, vinyl, digital)
              - Different release years for the same album
              - Artist name variations (e.g., "Depeche Mode" vs "DEPECHE MODE")
            CRITERIA
          end

          def non_match_criteria
            <<~CRITERIA.strip
              - Tribute albums or cover versions
              - Merchandise or non-music items
              - Different albums by the same artist
              - Compilation albums (unless the original is also a compilation)
              - Single songs from the album
              - Soundtracks containing songs from the album
            CRITERIA
          end

          # Override to use album-specific formatting with Artist field
          def format_search_result(result)
            title = result.dig("ItemInfo", "Title", "DisplayValue")
            contributors = result.dig("ItemInfo", "ByLineInfo", "Contributors") || []
            artist = contributors.find { |c| c["Role"] == "Artist" }&.dig("Name")
            binding = result.dig("ItemInfo", "Classifications", "Binding", "DisplayValue")
            manufacturer = result.dig("ItemInfo", "ByLineInfo", "Manufacturer", "DisplayValue")
            release_date = result.dig("ItemInfo", "ProductInfo", "ReleaseDate", "DisplayValue")

            <<~RESULT
              - ASIN: #{result["ASIN"]}
                Title: #{title}
                Artist: #{artist}
                Format: #{binding}
                Manufacturer: #{manufacturer}
                Release Date: #{release_date}
            RESULT
          end

          # Internal schema class
          class MatchResult < OpenAI::BaseModel
            required :asin, String, doc: "Amazon ASIN of the matching product"
            required :title, String, doc: "Product title from Amazon"
            required :artist, String, doc: "Artist name from Amazon"
            required :explanation, String, doc: "Brief explanation of why this is a match"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :matching_results, OpenAI::ArrayOf[MatchResult]
          end
        end
      end
    end
  end
end
