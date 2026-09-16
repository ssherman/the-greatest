# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Query object for Books::Book import requests. `title` is a required
      # keyword but may be nil or blank for an identifier-only import (e.g. an
      # Open Library work key or ISBN with no title resolved yet).
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :title, :author_names, :year, :isbn13, :isbn10, :asin, :goodreads_id, :open_library_work_key

        def initialize(title:, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [], goodreads_id: [], open_library_work_key: nil)
          @title = title
          @author_names = Array(author_names)
          @year = year
          @isbn13 = Array(isbn13)
          @isbn10 = Array(isbn10)
          @asin = Array(asin)
          @goodreads_id = Array(goodreads_id)
          @open_library_work_key = open_library_work_key
        end

        def valid?
          validation_errors.empty?
        end

        def validate!
          errors = validation_errors
          raise ArgumentError, errors.join(", ") if errors.any?
        end

        private

        def validation_errors
          errors = []

          if title.blank? && !identifier_present?
            errors << "Title is required when no identifier is provided"
          end

          if title.present? && !title.is_a?(String)
            errors << "Title must be a string"
          end

          if year.present? && !year.is_a?(Integer)
            errors << "Year must be an integer"
          end

          errors
        end

        def identifier_present?
          isbn13.any? || isbn10.any? || asin.any? || goodreads_id.any? || open_library_work_key.present?
        end
      end
    end
  end
end
