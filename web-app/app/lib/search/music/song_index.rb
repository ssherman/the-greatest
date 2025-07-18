# frozen_string_literal: true

module Search
  module Music
    class SongIndex < ::Search::Base::Index
      def self.model_klass
        ::Music::Song
      end

      def self.model_includes
        [albums: :primary_artist]
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
              artist_names: {
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
