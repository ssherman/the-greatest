module Books
  class Author
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # The survivor's own non-blank value always wins; these are only filled when it
      # has none. `kind` and `exclude_from_rankings` are deliberately absent. `kind`
      # is NOT NULL with a default, so it is never blank -- and folding a pseudonym
      # into a person must not turn the person into a pseudonym. `exclude_from_rankings`
      # is a NOT NULL boolean defaulting to false, and `false.present?` is false, so
      # including it here would let a source's `true` silently overwrite a survivor's
      # `false` and drop the survivor out of the rankings.
      BLANK_FILLABLE = %i[sort_name birth_year death_year gender description].freeze

      attr_reader :source_author, :target_author, :stats, :affected_book_ids

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_author = source
        @target_author = target
        @stats = {}
        @affected_book_ids = []
      end

      def call
        if source_author.id == target_author.id
          return Result.new(
            success?: false,
            data: nil,
            errors: ["Cannot merge an author with itself"]
          )
        end

        ActiveRecord::Base.transaction do
          merge_all_associations
          reconcile_scalars
          target_author.save! if target_author.changed?
          destroy_source_author
        end

        run_post_commit_steps

        Result.new(success?: true, data: target_author, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        Result.new(success?: false, data: nil, errors: [error.message])
      rescue ActiveRecord::RecordNotUnique => error
        Result.new(success?: false, data: nil, errors: ["Constraint violation: #{error.message}"])
      rescue => error
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      # Unlike the games and books mergers there is no
      # collect_affected_ranking_configurations step: author rankings do not derive
      # from lists, so recalculation is one argument-less job rather than a set of
      # per-configuration ones, and there is nothing to capture before the destroy.
      def merge_all_associations
        merge_identifiers
        merge_external_links
        merge_ai_chats
        merge_images
        merge_category_items
        merge_descriptions
        merge_book_authors
        merge_credits
        merge_author_relationships
        merge_inverse_author_relationships
      end

      def merge_identifiers
        count = 0
        source_author.identifiers.find_each do |identifier|
          existing = target_author.identifiers.find_by(
            identifier_type: identifier.identifier_type,
            value: identifier.value
          )

          if existing
            identifier.destroy!
          else
            identifier.update!(identifiable_id: target_author.id)
            count += 1
          end
        end
        @stats[:identifiers] = count
      end

      def merge_external_links
        @stats[:external_links] = source_author.external_links.update_all(parent_id: target_author.id)
      end

      def merge_ai_chats
        @stats[:ai_chats] = source_author.ai_chats.update_all(parent_id: target_author.id)
      end

      def merge_images
        has_target_primary = target_author.primary_image.present?
        count = 0

        source_author.images.find_each do |image|
          image.update!(
            parent_id: target_author.id,
            primary: has_target_primary ? false : image.primary
          )
          count += 1
        end

        @stats[:images] = count
      end

      def merge_category_items
        count = 0
        source_author.category_items.find_each do |category_item|
          target_author.category_items.find_or_create_by!(category_id: category_item.category_id)
          count += 1
        end
        @stats[:category_items] = count
      end

      # Two unique indexes apply: one on
      # (describable, kind, locale, source, source_name) with nulls_not_distinct,
      # and a partial one allowing a single rank=1 row per (describable, kind, locale).
      def merge_descriptions
        preferred_keys = target_author.descriptions.select(&:preferred?)
          .map { |description| [description.kind, description.locale] }
          .to_set
        count = 0

        source_author.descriptions.find_each do |description|
          collides = target_author.descriptions.exists?(
            kind: description.kind,
            locale: description.locale,
            source: description.source,
            source_name: description.source_name
          )

          if collides
            description.destroy!
            next
          end

          attrs = {describable_id: target_author.id}
          if description.preferred? &&
              preferred_keys.include?([description.kind, description.locale])
            attrs[:rank] = :normal
          end

          description.update!(attrs)
          count += 1
        end
        @stats[:descriptions] = count
      end

      # Collected BEFORE any write: once the links are repointed there is no way to
      # tell which books changed authorship, and a book whose duplicate link was
      # *dropped* changed too -- it used to carry both authors and now carries one.
      #
      # delete_all/update_all rather than per-record destroy!/update!, for two
      # reasons. Books::BookAuthor has its own after_commit reindex hook that would
      # fire once per row and duplicate the batched fan-out run_post_commit_steps
      # already performs; and a prolific author can carry thousands of links, which
      # is a row-at-a-time query storm inside the merge transaction. The colliding
      # rows are deleted first, so the (book_id, author_id) unique index is never at
      # risk even though update_all skips the model's uniqueness validation.
      #
      # A subquery, not a plucked id list: this codebase has already hit
      # PostgreSQL's 65,535 bind-parameter cap with a large IN.
      #
      # `position` is not renumbered. It is scoped to the book, which does not
      # change, so every moved row keeps a valid position; a dropped duplicate can
      # leave a gap in one book's sequence, which is cosmetic.
      def merge_book_authors
        @affected_book_ids = source_author.book_ids

        dropped = ::Books::BookAuthor
          .where(author_id: source_author.id)
          .where(book_id: ::Books::BookAuthor.where(author_id: target_author.id).select(:book_id))
          .delete_all

        moved = ::Books::BookAuthor
          .where(author_id: source_author.id)
          .update_all(author_id: target_author.id)

        @stats[:book_authors] = moved
        @stats[:book_authors_dropped] = dropped
      end

      # books_credits has NO unique index, so the dedup key -- creditable + role --
      # is enforced here or not at all. Two rows crediting the same person as
      # translator of the same edition is exactly the duplicate a merge is supposed
      # to remove, and nothing downstream would reject it.
      def merge_credits
        count = 0
        source_author.credits.find_each do |credit|
          collides = target_author.credits.exists?(
            creditable_type: credit.creditable_type,
            creditable_id: credit.creditable_id,
            role: credit.role
          )

          if collides
            credit.destroy!
          else
            credit.update!(author_id: target_author.id)
            count += 1
          end
        end
        @stats[:credits] = count
      end

      # Repoints from_author_id. Two rows must be dropped instead: one that already
      # points AT the target (repointing it makes the survivor relate to itself,
      # which no_self_reference rejects and the whole merge would roll back on), and
      # one the target already holds, which the (from, to, relation_type) unique
      # index would reject.
      def merge_author_relationships
        count = 0
        source_author.author_relationships.find_each do |relationship|
          if relationship.to_author_id == target_author.id
            relationship.destroy!
            next
          end

          collides = ::Books::AuthorRelationship.exists?(
            from_author_id: target_author.id,
            to_author_id: relationship.to_author_id,
            relation_type: relationship.relation_type
          )

          if collides
            relationship.destroy!
          else
            relationship.update!(from_author_id: target_author.id)
            count += 1
          end
        end
        @stats[:author_relationships] = count
      end

      # The mirror image: repoints to_author_id, with the same two drops. Direction
      # is meaningful (A is a pseudonym of B is not B is a pseudonym of A), so a
      # relationship that survives in one direction is not a duplicate of one in the
      # other and both are kept.
      def merge_inverse_author_relationships
        count = 0
        source_author.inverse_author_relationships.find_each do |relationship|
          if relationship.from_author_id == target_author.id
            relationship.destroy!
            next
          end

          collides = ::Books::AuthorRelationship.exists?(
            from_author_id: relationship.from_author_id,
            to_author_id: target_author.id,
            relation_type: relationship.relation_type
          )

          if collides
            relationship.destroy!
          else
            relationship.update!(to_author_id: target_author.id)
            count += 1
          end
        end
        @stats[:inverse_author_relationships] = count
      end

      def reconcile_scalars
        fill_blank_fields
        absorb_alternate_names
      end

      def fill_blank_fields
        filled = []

        BLANK_FILLABLE.each do |field|
          next if target_author.public_send(field).present?

          value = source_author.public_send(field)
          next if value.blank?

          target_author.public_send(:"#{field}=", value)
          filled << field
        end

        @stats[:filled_fields] = filled
      end

      # Absorbing the duplicate's name is often the whole point of the merge: folding
      # "J.R.R. Tolkien" into "J. R. R. Tolkien" should leave the deleted spelling
      # findable. alternate_names is GIN-indexed and feeds as_indexed_json, so the
      # search index picks this up on the target's reindex.
      def absorb_alternate_names
        existing = Array(target_author.alternate_names)
        incoming = ([source_author.name] + Array(source_author.alternate_names))
          .map { |value| value.to_s.strip }
          .compact_blank

        merged = (existing + incoming).uniq - [target_author.name]
        return if merged == existing

        @stats[:alternate_names_added] = merged - existing
        target_author.alternate_names = merged
      end

      def run_post_commit_steps
      end

      def destroy_source_author
        source_author.destroy!
      end
    end
  end
end
