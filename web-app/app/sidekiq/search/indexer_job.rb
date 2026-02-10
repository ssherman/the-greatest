# frozen_string_literal: true

class Search::IndexerJob
  include Sidekiq::Job

  def perform
    Rails.logger.info "Starting search indexing job"

    # Process each indexed model type
    %w[Music::Artist Music::Album Music::Song Games::Game].each do |model_type|
      process_requests_for_type(model_type)
    end

    Rails.logger.info "Completed search indexing job"
  end

  private

  def process_requests_for_type(model_type)
    requests = SearchIndexRequest.for_type(model_type)
      .oldest_first
      .limit(1000)

    return if requests.empty?

    Rails.logger.info "Processing #{requests.size} search index requests for #{model_type}"

    # Group by parent and action to deduplicate - only process each item once per action
    grouped_requests = requests.group_by { |r| [r.parent_type, r.parent_id, r.action] }

    Rails.logger.info "Deduplicated to #{grouped_requests.size} unique items for #{model_type}"

    domain = model_type.deconstantize  # "Music" or "Games"
    model_name = model_type.demodulize  # "Artist" or "Game"
    index_class = "Search::#{domain}::#{model_name}Index".constantize

    # Process each unique item
    items_to_index = []
    items_to_unindex = []
    all_processed_request_ids = []

    grouped_requests.each do |(parent_type, parent_id, action), request_group|
      # Collect all request IDs for cleanup
      all_processed_request_ids.concat(request_group.map(&:id))

      if action == "index_item"
        # Find the actual model - skip if deleted
        model = model_type.constantize.find_by(id: parent_id)
        if model
          items_to_index << model
        else
          Rails.logger.warn "Skipping indexing for deleted #{model_type} ID #{parent_id}"
        end
      else # unindex_item
        items_to_unindex << parent_id
      end
    end

    # Bulk index all items that need indexing
    if items_to_index.any?
      Rails.logger.info "Bulk indexing #{items_to_index.size} unique #{model_type} items"

      # Include necessary associations for efficient indexing
      if index_class.model_includes.any?
        item_ids = items_to_index.map(&:id)
        items_to_index = model_type.constantize.where(id: item_ids).includes(index_class.model_includes).to_a
      end

      index_class.bulk_index(items_to_index)
    end

    # Bulk unindex all items that need unindexing
    if items_to_unindex.any?
      Rails.logger.info "Bulk unindexing #{items_to_unindex.size} unique #{model_type} items"
      index_class.bulk_unindex(items_to_unindex)
    end

    # Clean up ALL processed requests (including duplicates)
    SearchIndexRequest.where(id: all_processed_request_ids).delete_all
    Rails.logger.info "Cleaned up #{all_processed_request_ids.size} processed requests for #{model_type} (including duplicates)"
  end
end
