# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class KeepBiggerWorkTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @war = books_books(:war_and_peace) # Leo Tolstoy
          @got = books_books(:got) # Stephen King
          ::Books::VerificationJob.jobs.clear
        end

        def tolstoy(key, title, editions) = ol_work(key, title: title, authors: [["OL1A", "Leo Tolstoy"]], editions: editions)

        def king(key, title, editions) = ol_work(key, title: title, authors: [["OL2A", "Stephen King"]], editions: editions)

        def settled(book, new_key:, old_keys:, **attrs)
          Identifier.create!(identifiable: book, identifier_type: :books_work_openlibrary_id, value: new_key, source: :open_library)
          ::Books::Verification.create!({book: book, work_outcome: :replaced, run_id: "old", stage: :done, lookup: :identifiers,
                                         new_key: new_key, old_keys: old_keys}.merge(attrs))
        end

        def work_keys(book) = book.identifiers.where(identifier_type: :books_work_openlibrary_id).order(:value).pluck(:value, :source)

        # Production, 2026-10-26: Seize the Day held a 30-edition work and the
        # matcher moved it to a 1-edition one.
        test "a dry run finds a book whose old work passes our check and has more editions, and writes nothing" do
          row = settled(@war, new_key: "OL5W", old_keys: ["OL9W"])
          client = FakeOlClient.new(works: {"OL5W" => tolstoy("OL5W", "War and Peace (Penguin Classics)", 1), "OL9W" => tolstoy("OL9W", "War and Peace", 30)})

          result = Sidekiq::Testing.fake! { KeepBiggerWork.call(client: client) }

          assert_equal [1, 0, nil], result.data.values_at(:found, :reverted, :run_id)
          assert_match(/book #{@war.id} .*OL5W.*1 edition.*OL9W.*30 editions/, result.data[:samples].first)
          assert_equal ["replaced", [["OL5W", "open_library"]]], [row.reload.work_outcome, work_keys(@war)]
          assert_empty ::Books::VerificationJob.jobs
        end

        # Women (Bukowski) held The Woman in White: a bigger old work that fails
        # our check is another book.
        test "an old work that fails our check, one with fewer editions, and one that redirects to the new work are not found" do
          settled(@war, new_key: "OL5W", old_keys: ["OL9W", "OL8W", "OL7W"])
          client = FakeOlClient.new(works: {
            "OL5W" => tolstoy("OL5W", "War and Peace", 10),
            "OL9W" => tolstoy("OL9W", "Anna Karenina", 653),
            "OL8W" => tolstoy("OL8W", "War and Peace", 2),
            "OL7W" => tolstoy("OL5W", "War and Peace", 10)
          })

          assert_equal 0, KeepBiggerWork.call(client: client).data[:found]
        end

        test "apply reverts each book found and queues one redo run over them" do
          settled(@war, new_key: "OL5W", old_keys: ["OL9W"])
          second = settled(@got, new_key: "OL6W", old_keys: ["OL8W"], second_chance_at: 1.day.ago,
            prior_outcome: ::Books::Verification.work_outcomes["unsure"], prior_keys: ["OL8W"])
          client = FakeOlClient.new(works: {
            "OL5W" => tolstoy("OL5W", "War and Peace", 1), "OL9W" => tolstoy("OL9W", "War and Peace", 30),
            "OL6W" => king("OL6W", "A Game of Thrones", 2), "OL8W" => king("OL8W", "A Game of Thrones", 40)
          })

          result = Sidekiq::Testing.fake! { KeepBiggerWork.call(apply: true, client: client) }

          assert_equal [2, 2, []], result.data.values_at(:found, :reverted, :failed)
          assert_equal [["OL9W", "legacy"]], work_keys(@war)
          assert_equal "reverted", ::Books::Verification.find_by(book: @war).work_outcome
          assert_equal ["unsure", [["OL8W", "legacy"]]], [second.reload.work_outcome, work_keys(@got)]
          job = ::Books::VerificationJob.jobs.sole
          assert_equal [nil, result.data[:run_id], %w[redo unranked post_import], [@war.id, @got.id].sort], job["args"].then { |args| [args[0], args[1], args[2], args[3].sort] }
        end

        test "apply with nothing found queues nothing" do
          result = Sidekiq::Testing.fake! { KeepBiggerWork.call(apply: true, client: FakeOlClient.new) }

          assert_equal [0, nil], result.data.values_at(:found, :run_id)
          assert_empty ::Books::VerificationJob.jobs
        end
      end
    end
  end
end
