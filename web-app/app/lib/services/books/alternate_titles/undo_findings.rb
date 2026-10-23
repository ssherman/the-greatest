# frozen_string_literal: true

module Services
  module Books
    module AlternateTitles
      # The verification pass trusted an identifier when its edition's title
      # agreed with the book's title or one of its alternate titles. Once the
      # AI review has removed an alternate title, a finding that agreed ONLY
      # through a removed title has nothing left to stand on. This undoes
      # those findings (destroys the identifier the pass added, puts a
      # confirmed one back to its previous source) and nothing else. The
      # findings stay, marked with undone_at and undo_action, so redo can
      # reverse one.
      #
      # Per book with a removed title not yet checked (undo_checked_at):
      # kept_view is the book's title plus its kept and review titles,
      # full_view adds every removed title. A finding is undone when it
      # agrees under full_view and no longer under kept_view. When the
      # settled Open Library work only agrees through a removed title (a
      # wrong work), its own title does not count for the kept side either.
      class UndoFindings
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        TitleView = Data.define(:title, :alternate_titles)
        EditionLike = Data.define(:title, :subtitle)
        RecordLike = Data.define(:title, :subtitle, :creator, :contributors)

        FETCH_SLICE = 50
        SAMPLE_LIMIT = 20
        SOURCES = %w[open_library worldcat].freeze
        WORK_KEY = ::Services::Books::Verification::ApplyBook::WORK_KEY

        def self.call(apply: false, client: ::Books::OpenLibrary::Client.new)
          new(apply: apply, client: client).call
        end

        # Reverses one undone finding: recreates the identifier (or sets its
        # source back) and clears the undo marks.
        def self.redo(finding:)
          return failure("finding #{finding.id} is not undone") if finding.undone_at.nil?

          error = case finding.undo_action
          when "identifier_destroyed" then recreate(finding)
          when "source_restored" then restore_source(finding)
          end
          return failure(error) if error

          finding.update!(undone_at: nil, undo_action: nil)
          Result.new(success?: true, data: {finding: finding}, errors: [])
        end

        def self.recreate(finding)
          type, value = finding.identifier_type, finding.value
          others = ::Identifier.where(identifiable_type: "Books::Book", identifier_type: type, value: value).where.not(identifiable_id: finding.book_id)
          if others.verified.exists?
            return "another book holds #{type} #{value} as a verified identifier"
          end

          identifier = ::Identifier.find_or_initialize_by(identifiable_type: "Books::Book", identifiable_id: finding.book_id, identifier_type: type, value: value)
          identifier.source = finding.source
          identifier.save!
          finding.identifier_id = identifier.id
          nil
        end

        def self.restore_source(finding)
          identifier = ::Identifier.find_by(id: finding.identifier_id, identifiable_type: "Books::Book", identifiable_id: finding.book_id)
          return "the identifier of finding #{finding.id} is gone" unless identifier

          identifier.update!(source: finding.source)
          nil
        end

        def self.failure(message) = Result.new(success?: false, data: nil, errors: [message])

        private_class_method :recreate, :restore_source, :failure

        def initialize(apply:, client:)
          @apply = apply
          @client = client
          @counts = {identifier_destroyed: 0, source_restored: 0, identifier_gone: 0}
          @wrong_work = []
          @samples = []
          @checked = 0
        end

        def call
          book_ids = ::AlternateTitle.where(titleable_type: "Books::Book", status: :removed, undo_checked_at: nil).distinct.pluck(:titleable_id)
          books = ::Books::Book.where(id: book_ids).order(:id).to_a
          verifications = ::Books::Verification.where(book_id: book_ids).index_by(&:book_id)
          keys = books.to_h { |book| [book.id, work_key(book, verifications[book.id])] }
          works = fetch_works(keys.values.compact.uniq)

          books.each { |book| process(book, verifications[book.id], keys[book.id], works) }

          Result.new(success?: true, errors: [], data: {books: books.size, findings_checked: @checked, undone: @counts,
                                                        wrong_work: @wrong_work, samples: @samples})
        end

        private

        def work_key(book, verification)
          return nil unless verification && ::Books::Verification::KEYED_OUTCOMES.include?(verification.work_outcome)
          return verification.new_key if verification.new_key.present?

          held = book.identifiers.where(identifier_type: WORK_KEY).pluck(:value).uniq
          held.first if held.size == 1
        end

        def fetch_works(keys)
          keys.each_slice([FETCH_SLICE, ::Books::OpenLibrary::Client::MAX_BATCH].min).each_with_object({}) do |slice, works|
            works.merge!(@client.works_batch(slice))
          end
        end

        def process(book, verification, key, works)
          rows = ::AlternateTitle.where(titleable_type: "Books::Book", titleable_id: book.id)
          kept = rows.where(status: [:kept, :review]).order(:id).pluck(:title)
          removed = rows.where(status: :removed).order(:id).pluck(:title)
          kept_view = TitleView.new(book.title, kept)
          full_view = TitleView.new(book.title, kept + removed)
          work = works[key] if key
          note(book, "work not found (#{key})") if key && work.nil?
          wrong = !work.nil? && !Verification::Check.titles_agree?(kept_view, work) && Verification::Check.titles_agree?(full_view, work)
          @wrong_work << {book_id: book.id, title: book.title, work_key: key, work_title: work.title} if wrong

          ::ActiveRecord::Base.transaction do
            undo_book(book, verification, kept_view, full_view, work, wrong) if verification
            rows.where(status: :removed, undo_checked_at: nil).update_all(undo_checked_at: Time.current) if @apply
          end
        end

        def undo_book(book, verification, kept_view, full_view, work, wrong)
          findings = verification.findings.not_undone.where(kind: [:added, :confirmed], source: SOURCES).order(:id).to_a
          findings = findings.select { |finding| evidence_title(finding) }.sort_by { |finding| finding.confirmed? ? 0 : 1 }
          # id => source an earlier undo in this book left the identifier with (dry runs write nothing).
          state = {}
          findings.each do |finding|
            @checked += 1
            next unless agrees?(full_view, work, finding)
            next if agrees?(kept_view, wrong ? nil : work, finding)

            action = undo(finding, book, state)
            @counts[action] += 1
            note(book, "#{finding.kind} #{finding.identifier_type} #{finding.value} via \"#{evidence_title(finding)}\" -> #{action}")
            finding.update!(undone_at: Time.current, undo_action: action) if @apply
          end
        end

        def undo(finding, book, state)
          identifier = ::Identifier.find_by(id: finding.identifier_id, identifiable_type: "Books::Book", identifiable_id: book.id)
          source = state.fetch(identifier&.id) { identifier&.source }
          return :identifier_gone if identifier.nil? || source == :destroyed || source != finding.source

          if finding.added?
            identifier.destroy! if @apply
            state[identifier.id] = :destroyed
            :identifier_destroyed
          else
            identifier.update!(source: finding.previous_source) if @apply
            state[identifier.id] = finding.previous_source
            :source_restored
          end
        end

        def agrees?(view, work, finding)
          if finding.source_open_library?
            Verification::EditionCheck.title_agrees?(view, work, EditionLike.new(title: finding.evidence["title"], subtitle: nil))
          else
            records(finding).any? do |record|
              Verification::EditionCheck.title_agrees?(view, nil, Verification::WorldCatCheck.work_like(record_like(record)))
            end
          end
        end

        def records(finding) = Array(finding.evidence["records"]).select { |record| record.is_a?(Hash) }

        def record_like(record)
          RecordLike.new(title: record["title"], subtitle: nil, creator: record["creator"], contributors: [])
        end

        def evidence_title(finding)
          if finding.source_open_library?
            finding.evidence["title"].presence
          else
            records(finding).filter_map { |record| record["title"].presence }.first
          end
        end

        def note(book, text)
          @samples << "book #{book.id} #{book.title}: #{text}" if @samples.size < SAMPLE_LIMIT
        end
      end
    end
  end
end
