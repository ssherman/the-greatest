# frozen_string_literal: true

module Services
  module Lists
    class ImportService
      def self.call(list)
        new(list).call
      end

      def initialize(list)
        @list = list
      end

      def call
        return failure("List has no raw HTML") if @list.raw_html.blank?

        # Step 1: Simplify HTML
        simplified_html = Services::Html::SimplifierService.call(@list.raw_html)
        @list.update!(simplified_html: simplified_html)

        # Step 2: Parse with appropriate AI task
        parser_class = determine_parser_class
        return failure("No parser available for list type: #{@list.type}") unless parser_class

        # Step 3: Execute AI parsing
        result = parser_class.new(parent: @list).call

        if result.success?
          success(result.data)
        else
          failure(result.error)
        end
      end

      private

      def determine_parser_class
        case @list.type
        when "Music::Albums::List"
          Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask
        when "Music::Songs::List"
          Services::Ai::Tasks::Lists::Music::SongsRawParserTask
        when "Books::List"
          Services::Ai::Tasks::Lists::Books::RawParserTask
        when "Movies::List"
          Services::Ai::Tasks::Lists::Movies::RawParserTask
        when "Games::List"
          Services::Ai::Tasks::Lists::Games::RawParserTask
        end
      end

      def success(data)
        {success: true, data: data}
      end

      def failure(error)
        {success: false, error: error}
      end
    end
  end
end
