# frozen_string_literal: true

module SearchIndexable
  extend ActiveSupport::Concern

  included do
    after_commit :queue_for_indexing, on: [:create, :update]
    after_commit :queue_for_unindexing, on: :destroy
  end

  private

  def queue_for_indexing
    return if Services::BooksMigration.search_indexing_suppressed?
    SearchIndexRequest.create!(parent: self, action: :index_item)
  end

  def queue_for_unindexing
    return if Services::BooksMigration.search_indexing_suppressed?
    SearchIndexRequest.create!(parent: self, action: :unindex_item)
  end
end
