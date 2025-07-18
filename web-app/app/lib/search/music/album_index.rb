# frozen_string_literal: true

module Search
  module Music
    class AlbumIndex < ::Search::Base::Index
      def self.model_klass
        ::Music::Album
      end

      def self.model_includes
        [:primary_artist]
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
              title: {
                type: "text",
                analyzer: "folding",
                fields: {
                  keyword: {
                    type: "keyword",
                    normalizer: "lowercase"
                  }
                }
              },
              primary_artist_name: {
                type: "text",
                analyzer: "folding",
                fields: {
                  keyword: {
                    type: "keyword",
                    normalizer: "lowercase"
                  }
                }
              }
            }
          }
        }
      end
    end
  end
end
