# frozen_string_literal: true

module Search
  module Music
    class SongIndex < ::Search::Base::Index
      def self.model_klass
        ::Music::Song
      end

      def self.model_includes
        [:artists, :albums]
      end

      def self.index_definition
        {
          settings: {
            analysis: {
              filter: {
                edge_ngram_filter: {
                  type: "edge_ngram",
                  min_gram: 3,
                  max_gram: 20
                },
                ascii_folding_with_preserve: {
                  type: "asciifolding",
                  preserve_original: true
                }
              },
              analyzer: {
                folding: {
                  tokenizer: "standard",
                  filter: ["lowercase", "asciifolding"]
                },
                autocomplete: {
                  type: "custom",
                  tokenizer: "standard",
                  filter: [
                    "lowercase",
                    "edge_ngram_filter",
                    "ascii_folding_with_preserve"
                  ]
                },
                autocomplete_search: {
                  type: "custom",
                  tokenizer: "standard",
                  filter: [
                    "lowercase",
                    "ascii_folding_with_preserve"
                  ]
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
                  },
                  autocomplete: {
                    type: "text",
                    analyzer: "autocomplete",
                    search_analyzer: "autocomplete_search"
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
              },
              artist_ids: {
                type: "keyword"
              },
              album_ids: {
                type: "keyword"
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
