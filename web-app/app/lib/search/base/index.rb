# frozen_string_literal: true

module Search
  module Base
    class Index
      def self.client
        @client ||= OpenSearch::Client.new(host: ENV.fetch("OPENSEARCH_URL"))
      end

      def self.index_name
        base_name = derive_index_name_from_class
        if Rails.env.test?
          # Use process ID to make index names unique per test worker
          "#{base_name}_#{Process.pid}"
        else
          base_name
        end
      end

      def self.index_definition
        raise NotImplementedError, "Subclasses must implement index_definition"
      end

      def self.model_klass
        raise NotImplementedError, "Subclasses must implement model_klass"
      end

      def self.model_includes
        # Override in subclasses if eager loading is needed
        []
      end

      # Derive index name from class name
      # Search::Music::ArtistIndex -> music_artists_development
      def self.derive_index_name_from_class
        class_parts = name.split("::")

        # Remove 'Search' prefix and 'Index' suffix
        domain = class_parts[1]&.downcase # 'Music' -> 'music'
        model = class_parts[2]&.gsub(/Index$/, "")&.underscore&.pluralize # 'ArtistIndex' -> 'artists'

        "#{domain}_#{model}_#{Rails.env}"
      end

      private_class_method :derive_index_name_from_class

      def self.delete_index
        client.indices.delete(index: index_name)
        Rails.logger.info "Index '#{index_name}' deleted successfully."
      rescue OpenSearch::Transport::Transport::Errors::NotFound => e
        Rails.logger.error "Index '#{index_name}' does not exist. Error: #{e.message}"
      end

      def self.create_index
        # Only create the index if it doesn't already exist
        if index_exists?
          Rails.logger.info "Index '#{index_name}' already exists, skipping creation."
          return
        end

        client.indices.create(
          index: index_name,
          body: index_definition
        )
        Rails.logger.info "Index '#{index_name}' created successfully."
      rescue OpenSearch::Transport::Transport::Errors::BadRequest => e
        Rails.logger.error "Failed to create index '#{index_name}'. Error: #{e.message}"
        raise
      end

      def self.index_exists?
        client.indices.exists(index: index_name)
      end

      def self.bulk_index(items)
        return if items.empty?

        actions = []
        items.each do |item|
          actions << {
            index: {_index: index_name, _id: item.id, data: item.as_indexed_json}
          }
        end

        response = client.bulk(body: actions, refresh: true)

        if response["errors"]
          response["items"].each do |item|
            if item["index"]["error"]
              Rails.logger.error "Failed to index item ID #{item["index"]["_id"]}: #{item["index"]["error"]}"
            end
          end
        else
          Rails.logger.info "Successfully indexed batch of #{items.size} items to '#{index_name}'"
        end

        response
      end

      def self.index_item(item)
        response = client.index(
          index: index_name,
          id: item.id,
          body: item.as_indexed_json,
          refresh: true
        )
        Rails.logger.info "Successfully indexed item ID #{item.id} to '#{index_name}'"
        response
      rescue => e
        Rails.logger.error "Failed to index item ID #{item.id} to '#{index_name}'. Error: #{e.message}"
        raise
      end

      def self.unindex_item(item_id)
        client.delete(index: index_name, id: item_id)
        Rails.logger.info "Successfully removed item ID #{item_id} from '#{index_name}'"
      rescue OpenSearch::Transport::Transport::Errors::NotFound => e
        Rails.logger.error "Item ID #{item_id} not found in index '#{index_name}'. Error: #{e.message}"
      end

      def self.find_by_id(item_id)
        response = client.get(index: index_name, id: item_id)
        response["_source"]
      rescue OpenSearch::Transport::Transport::Errors::NotFound => e
        Rails.logger.error "Item ID #{item_id} not found in index '#{index_name}'. Error: #{e.message}"
        nil
      end

      def self.refresh_index
        client.indices.refresh(index: index_name)
        Rails.logger.info "Index '#{index_name}' refreshed successfully."
      end

      # Standard interface methods - same for all index types
      def self.index(model)
        index_item(model)
      end

      def self.unindex(model)
        unindex_item(model.id)
      end

      def self.find(id)
        find_by_id(id)
      end

      def self.reindex_all
        model_name = model_klass.name.demodulize.downcase.pluralize
        Rails.logger.info "Starting reindex of all #{model_name}"

        delete_index if index_exists?
        create_index

        query = model_klass
        query = query.includes(model_includes) if model_includes.any?

        query.find_in_batches(batch_size: 1000) do |batch|
          bulk_index(batch)
        end

        Rails.logger.info "Completed reindex of all #{model_name}"
      end
    end
  end
end
