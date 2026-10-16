# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 3: the book's held ISBNs not yet verified, each
      # looked up in WorldCat (one GET /isbns per ISBN, ~2.7 s on the home
      # server). An agreeing record confirms the ISBN (both forms) as
      # worldcat and adds its OCLC number; records that all clearly differ
      # are a wrong_identifier finding. Runs whatever stage 1 decided.
      class ConfirmWithWorldCat
        MAX_WORLDCAT_ISBNS = 50
        ISBN_TYPES = %w[books_work_isbn13 books_work_isbn10].freeze

        def self.call(verification:, client:, dump_date:)
          new(verification, client, dump_date).call
        end

        def self.max_isbns = MAX_WORLDCAT_ISBNS

        def initialize(verification, client, dump_date)
          @row = verification
          @client = client
          @dump_date = dump_date
          @book = verification.book
        end

        def call
          held = @book.identifiers.unverified.where(identifier_type: ISBN_TYPES).order(:id).to_a
          isbns = held.filter_map { |identifier| ::Books::Isbn.normalize(identifier.value)&.isbn13 }.uniq.first(self.class.max_isbns)
          records = isbns.to_h { |isbn| [isbn, lookup(isbn)] }

          ::ActiveRecord::Base.transaction do
            records.each { |isbn, found| judge(isbn, found, held) }
            Counts.call(@row)
            @row.update!(stage: :signals, stage_error: nil, worldcat_dump_date: @dump_date)
          end
        end

        private

        # The service answers 504 after its 5 s deadline, and a popular ISBN can
        # take 3-5 s: that ISBN has no answer, it must not stop the book or the run.
        def lookup(isbn)
          @client.record_by_isbn(isbn)
        rescue ::Books::WorldCat::Exceptions::ServerError => error
          raise unless error.status_code == 504

          []
        end

        def judge(isbn, found, held)
          agreeing = found.select { |record| WorldCatCheck.agrees?(@book, record) }
          if agreeing.any?
            evidence = {"records" => agreeing.map { |record| summary(record) }}
            held.select { |identifier| ::Books::Isbn.normalize(identifier.value)&.isbn13 == isbn }.each do |identifier|
              Stamp.confirm(verification: @row, identifier: identifier, source: :worldcat, evidence: evidence)
            end
            agreeing.map(&:oclc).compact.uniq.each do |oclc|
              Stamp.call(verification: @row, type: "books_work_oclc_id", value: oclc.to_s, source: :worldcat, evidence: evidence)
            end
          elsif found.any? && found.all? { |record| WorldCatCheck.clearly_different?(@book, record) }
            Stamp.finding(@row, :wrong_identifier, "books_work_isbn13", isbn, evidence: {"records" => found.map { |record| summary(record) }})
          end
        end

        def summary(record)
          {"oclc" => record.oclc, "title" => record.title, "creator" => record.creator, "year" => record.year}
        end
      end
    end
  end
end
