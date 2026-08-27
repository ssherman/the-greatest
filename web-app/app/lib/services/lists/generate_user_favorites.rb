# frozen_string_literal: true

module Services
  module Lists
    # Persists a domain's UserFavoritesTally into its generated List.
    #
    # The list is found by (type, auto_generated_kind), never by name -- the
    # legacy implementation looked its lists up by name and could not survive a
    # rename.
    #
    # Items are written with delete_all / insert_all, which skip the ListItem
    # callbacks and validations. That is deliberate on both counts: the guard
    # added in ListItem exists to stop humans editing generated rows, and it
    # needs no escape hatch for this class.
    class GenerateUserFavorites
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(user_list_class:, **options)
        new(user_list_class: user_list_class, **options).call
      end

      def initialize(user_list_class:, **options)
        @user_list_class = user_list_class
        @options = options
      end

      def call
        tally = UserFavoritesTally.call(user_list_class: @user_list_class, **@options)
        list = find_or_create_list

        ::List.transaction do
          list.list_items.delete_all
          ::ListItem.insert_all(item_rows(list, tally.entries)) if tally.entries.any?
          list.update!(number_of_voters: tally.ballot_count)
        end

        Result.new(
          success?: true,
          data: {list: list, item_count: tally.entries.size, ballot_count: tally.ballot_count},
          errors: []
        )
      rescue => error
        # full_message, not just error.message: the Result carries only the
        # message, and GenerateUserFavoritesListsJob re-raises a RuntimeError of
        # its own -- so Sidekiq records that job's backtrace and the original is
        # gone unless it is written down here.
        Rails.logger.error {
          "#{self.class.name} failed for #{@user_list_class}: " \
            "#{error.full_message(highlight: false, order: :top)}"
        }
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      def find_or_create_list
        klass = @user_list_class.generated_list_class

        # STI scopes this to the domain's own List subclass via the type column,
        # so the partial unique index on (type, auto_generated_kind) is what makes
        # "one generated list per domain" true.
        klass.find_or_create_by!(auto_generated_kind: :user_favorites) do |list|
          list.name = @user_list_class.generated_list_name
          list.description = @user_list_class.generated_list_description
          list.source = "The Greatest Users"
          # New domains start switched off: visible in admin, contributing nothing
          # to rankings until someone activates them deliberately.
          list.status = :unapproved
        end
      end

      def item_rows(list, entries)
        now = Time.current
        listable_type = @user_list_class.listable_class.name

        entries.each_with_index.map do |entry, index|
          {
            list_id: list.id,
            listable_id: entry.listable_id,
            listable_type: listable_type,
            position: index + 1,
            verified: true,
            metadata: {voter_count: entry.voter_count, score: entry.score.round(6)},
            created_at: now,
            updated_at: now
          }
        end
      end
    end
  end
end
