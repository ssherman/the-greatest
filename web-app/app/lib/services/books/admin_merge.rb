# frozen_string_literal: true

module Services
  module Books
    # The Admin API's merge: validates, picks the merger for the record class
    # and turns the merger's `stats` into warnings an API client can read.
    #
    # The stats keys are interpreted in three places that must change together:
    # Actions::Admin::Books::MergeBook, Actions::Admin::Books::MergeAuthor (the
    # UI wording) and this service (the API wording). Root-anchor every Books::
    # constant: a bare one resolves to Services::Books.
    #
    # Never wrap this in a transaction: the mergers refuse to run inside one
    # (see the comment on ::Books::Book::Merger#call).
    class AdminMerge
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      MERGERS = {
        "Books::Book" => "Books::Book::Merger",
        "Books::Author" => "Books::Author::Merger"
      }.freeze

      def self.call(source:, target:, dry_run: false)
        new(source:, target:, dry_run:).call
      end

      def initialize(source:, target:, dry_run: false)
        raise ArgumentError, "source and target must be the same class" unless source.instance_of?(target.class)
        raise ArgumentError, "#{source.class} cannot be merged" unless MERGERS.key?(source.class.name)

        @source = source
        @target = target
        @dry_run = dry_run
      end

      def call
        return failure(["Cannot merge a record with itself"]) if @source.id == @target.id
        return success([]) if @dry_run

        merger = MERGERS.fetch(@source.class.name).constantize.new(source: @source, target: @target)
        result = merger.call
        return failure(result.errors) unless result.success?

        success(warnings_for(merger.stats))
      end

      private

      def book? = @source.is_a?(::Books::Book)

      def warnings_for(stats)
        warnings = []

        if stats[:post_commit_error].present?
          what = book? ? "Search reindexing, ranking recalculation and the generated favorites rebuild" : "Search reindexing and ranking recalculation"
          warnings << {code: "post_commit_error",
                       detail: "#{what} could not be scheduled (#{stats[:post_commit_error]}); they will need to be re-run."}
        end

        if book?
          {book_authors_not_transferred: "author", credits_not_transferred: "credit"}.each do |key, noun|
            count = stats[key].to_i
            next unless count.positive?

            warnings << {code: key.to_s,
                         detail: "#{count} #{noun}(s) did not transfer because the surviving book already has its own."}
          end
        end

        warnings
      end

      def success(warnings) = Result.new(success?: true, data: {warnings: warnings}, errors: [])

      def failure(errors) = Result.new(success?: false, data: nil, errors: errors)
    end
  end
end
