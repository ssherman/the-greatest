# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The one way an admin makes an author, from the admin page and the API.
      # attrs are the author's own columns (string keys; alternate_names is an
      # array, normalised by the model). A Wikidata id is stored through
      # Identifiers::AdminWrite in the same transaction, so it is an admin-sourced
      # identifier and starts the author's enrichment; if that refuses, or the id
      # is already held, no author is created.
      #
      # The id check looks at every author row, provisional ones included: two
      # authors must never hold one Wikidata id. An author removed by a merge no
      # longer has a row, so its id is free again. The check runs under an advisory
      # lock on the id (see lock_qid), because the database cannot enforce this.
      #
      # Failures carry a code: :conflict (the id is held; data[:holder] is that
      # author) or :unprocessable (data[:author] is the unsaved author, with errors).
      class AdminCreate
        Result = Struct.new(:success?, :data, :errors, :code, keyword_init: true)

        QID_TYPE = "books_author_wikidata_qid"

        def self.call(attrs:, wikidata_qid: nil)
          new(attrs, wikidata_qid).call
        end

        # Serializes claims on one Wikidata id. The identifiers unique index includes
        # identifiable_id, so the database cannot stop two authors holding the same id;
        # this transaction-scoped advisory lock does. Call inside a transaction, then
        # check the holder under the lock.
        def self.lock_qid(value)
          ::Books::Author.connection.execute(
            ::Books::Author.sanitize_sql_array(["SELECT pg_advisory_xact_lock(hashtext(?))", "#{QID_TYPE}:#{value}"])
          )
        end

        def initialize(attrs, wikidata_qid)
          @attrs = attrs
          @qid = wikidata_qid
        end

        def call
          value = nil
          if @qid
            value = ::Services::Books::Identifiers::AdminWrite.normalize_value(QID_TYPE, @qid)
            return unprocessable(::Books::Author.new, ["wikidata_qid must be Q followed by digits, e.g. Q7243"]) unless value
          end

          author = build_author
          return author if author.is_a?(Result)

          result = nil
          ::ActiveRecord::Base.transaction do
            self.class.lock_qid(value) if value
            holder = holder_of(value)
            if holder
              result = conflict(holder, value)
              raise ::ActiveRecord::Rollback
            end

            unless author.save
              result = unprocessable(author, author.errors.full_messages)
              raise ::ActiveRecord::Rollback
            end

            if value
              written = ::Services::Books::Identifiers::AdminWrite.add(record: author, identifier_type: QID_TYPE, value: value)
              unless written.success?
                result = unprocessable(author, written.errors)
                raise ::ActiveRecord::Rollback
              end
            end

            result = Result.new(success?: true, data: {author: author}, errors: [])
          end
          result
        end

        private

        # An enum value that does not exist (kind) raises ArgumentError on assignment;
        # only that assignment turns into a 422.
        def build_author
          ::Books::Author.new(@attrs)
        rescue ::ArgumentError => e
          unprocessable(::Books::Author.new, [e.message])
        end

        def holder_of(value)
          return nil unless value

          ::Identifier.find_by(identifier_type: QID_TYPE, value: value)&.identifiable
        end

        def conflict(holder, value)
          Result.new(success?: false, data: {holder: holder}, errors: ["#{value} already belongs to author #{holder.id}, #{holder.name}."], code: :conflict)
        end

        def unprocessable(author, errors)
          Result.new(success?: false, data: {author: author}, errors: errors, code: :unprocessable)
        end
      end
    end
  end
end
