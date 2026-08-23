# frozen_string_literal: true

module Search
  module Shared
    # opensearch-ruby's bundled serializer calls MultiJson.load/dump, which
    # multi_json 1.21.1 deprecates in favour of MultiJSON.parse/generate. Same
    # gem and same adapter -- only the method names differ -- so this is a
    # drop-in that stops ~96 deprecation lines per test run.
    class Serializer
      include OpenSearch::Transport::Transport::Serializer::Base

      def load(string, options = {})
        ::MultiJSON.parse(string, options)
      end

      def dump(object, options = {})
        ::MultiJSON.generate(object, options)
      end
    end
  end
end
