# frozen_string_literal: true

module SearchIndexable
  extend ActiveSupport::Concern

  included do
    after_commit :queue_for_indexing, on: [:create, :update]
    after_destroy :queue_for_unindexing
  end

  private

  def queue_for_indexing
    SearchIndexRequest.create!(parent: self, action: :index_item)
  end

  def queue_for_unindexing
    SearchIndexRequest.create!(parent: self, action: :unindex_item)
  end
end
