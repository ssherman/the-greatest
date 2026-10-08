# frozen_string_literal: true

module Recommendations
  CategoryFact = Struct.new(:id, :category_type, :item_count, keyword_init: true)
end
