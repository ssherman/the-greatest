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
      # longer has a row, so its id is free again.
      #
      # Failures carry a code: :conflict (the id is held; data[:holder] is that
      # author) or :unprocessable (data[:author] is the unsaved author, with errors).
      class AdminCreate
        Result = Struct.new(:success?, :data, :errors, :code, keyword_init: true)

        QID_TYPE = "books_author_wikidata_qid"

        def self.call(attrs:, wikidata_qid: nil)
          new(attrs, wikidata_qid).call
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

          result = nil
          ::ActiveRecord::Base.transaction do
            holder = holder_of(value)
            if holder
              result = conflict(holder, value)
              raise ::ActiveRecord::Rollback
            end

            author = ::Books::Author.new(@attrs)
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
        rescue ::ActiveRecord::RecordNotUnique
          # Another request took the id between the check and the write.
          holder = holder_of(value)
          holder ? conflict(holder, value) : raise
        rescue ::ArgumentError => e
          # An enum value that does not exist (kind).
          unprocessable(::Books::Author.new, [e.message])
        end

        private

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
