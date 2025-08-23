# frozen_string_literal: true

module Search
  module Music
    class ArtistIndex < ::Search::Base::Index
      def self.model_klass
        ::Music::Artist
      end

      def self.index_definition
        {
          settings: {
            analysis: {
              analyzer: {
                folding: {
                  tokenizer: "standard",
                  filter: ["lowercase", "asciifolding"]
                }
              }
            }
          },
          mappings: {
            properties: {
              name: {
                type: "text",
                analyzer: "folding",
                fields: {
                  keyword: {
                    type: "keyword",
                    normalizer: "lowercase"
                  }
                }
              },
              category_ids: {
                type: "keyword"
              }
            }
          }
        }
      end
    end
  end
end
