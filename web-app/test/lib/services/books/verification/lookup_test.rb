# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class LookupTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # isbn13 9780140447934, Leo Tolstoy
          @work = ol_work("OL1W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]])
        end

        test "one work behind every identifier, agreeing, is settled by the fast pass" do
          client = FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")]}, works: {"OL1W" => @work})

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL1W", :identifiers, []], [answer.work.key, answer.lookup, answer.duplicates]
          assert_equal "2026-07-31", answer.source_version[:dump_date]
          assert_not client.calls.any? { |call| call.first == :resolve }
        end

        test "identifiers pointing at two works go to /resolve with everything we know" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")], ["goodreads", "656"] => [ol_hit("OL2W", id_type: "goodreads", value: "656")]},
            resolution: ol_resolution(verdict: "accept", work: @work)
          )

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL1W", :resolve], [answer.work.key, answer.lookup]
          resolve_args = client.calls.find { |call| call.first == :resolve }.last
          assert_equal "War and Peace", resolve_args[:title]
          assert_equal ["Leo Tolstoy"], resolve_args[:author_names]
          assert_equal ["9780140447934"], resolve_args[:isbn13]
          assert_equal ["656"], resolve_args[:goodreads_id]
          assert_nil resolve_args[:existing_ol_key]
        end

        test "a fast hit whose work disagrees on the title goes to /resolve" do
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL9W")]},
            works: {"OL9W" => ol_work("OL9W", title: "Anna Karenina", authors: [["OL1A", "Leo Tolstoy"]])},
            resolution: ol_resolution(verdict: "abstain")
          )

          answer = Lookup.call(book: @book, client: client)

          assert_nil answer.work
          assert_equal :resolve, answer.lookup
        end

        test "an identifier Open Library does not know (404) is no hit" do
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => ::Books::OpenLibrary::Exceptions::NotFoundError.new("no such isbn", 404)},
            resolution: ol_resolution(verdict: "accept", work: @work)
          )

          assert_equal :resolve, Lookup.call(book: @book, client: client).lookup
        end

        test "an identifier the service rejects (422) is no hit" do
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => ::Books::OpenLibrary::Exceptions::ClientError.new("bad isbn", 422)},
            resolution: ol_resolution(verdict: "accept", work: @work)
          )

          assert_equal :resolve, Lookup.call(book: @book, client: client).lookup
        end

        test "an identifier lookup answered 403 is raised, not treated as no hit" do
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => ::Books::OpenLibrary::Exceptions::ClientError.new("forbidden", 403)},
            resolution: ol_resolution(verdict: "accept", work: @work)
          )

          assert_raises(::Books::OpenLibrary::Exceptions::ClientError) { Lookup.call(book: @book, client: client) }
        end

        test "a book with no identifiers goes straight to /resolve with its stored key as a hint" do
          book = books_books(:crime_and_punishment) # holds OL262758W, no ISBN, no author
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: ol_work("OL262758W", title: "Crime and Punishment")))

          answer = Lookup.call(book: book, client: client)

          assert_equal "OL262758W", client.calls.find { |call| call.first == :resolve }.last[:existing_ol_key]
          assert_nil answer.work, "no author, so the check cannot pass"
        end

        test "an accepted work that fails our check is no answer" do
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: ol_work("OL5W", title: "Anna Karenina", authors: [["OL1A", "Leo Tolstoy"]])))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "an accepted, agreeing work brings its duplicates (minus itself) and redirect sources" do
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: @work, duplicates: ["OL2W", "OL1W"], redirect_sources: ["OL0W"]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal [["OL2W"], ["OL0W"]], [answer.duplicates, answer.redirect_sources]
        end

        test "no more than MAX_FAST_LOOKUPS identifier calls" do
          12.times { |i| ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn10, value: "000000000#{i}") }
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain"))

          Lookup.call(book: @book, client: client)

          assert_equal Lookup::MAX_FAST_LOOKUPS, client.calls.count { |call| call.first == :identifier }
        end

        test "MAX_FAST_LOOKUPS is 5" do
          assert_equal 5, Lookup::MAX_FAST_LOOKUPS
        end

        test "an error raised by one of the concurrent identifier lookups propagates" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          client = FakeOlClient.new(hits: {["goodreads", "656"] => ::Books::OpenLibrary::Exceptions::ServerError.new("down", 500)})

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { Lookup.call(book: @book, client: client) }
        end

        test "a missing identifier among concurrent lookups is no hit and the others still settle the book" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          work = ol_work("OL1W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")], ["goodreads", "656"] => ::Books::OpenLibrary::Exceptions::NotFoundError.new("none", 404)},
            works: {"OL1W" => work}
          )

          answer = Lookup.call(book: @book, client: client)

          assert_equal [:identifiers, "OL1W"], [answer.lookup, answer.work.key]
        end

        test "the fast pass fetches author records when the names differ, and settles on an alternate name" do
          work = ol_work("OL1W", title: "War and Peace", authors: [["OL1A", "Лев Толстой"]])
          client = FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")]}, works: {"OL1W" => work},
            authors: {"OL1A" => ol_author("OL1A", name: "Лев Толстой", alternate_names: ["Leo Tolstoy"])})

          answer = Lookup.call(book: @book, client: client)

          assert_equal [:identifiers, "OL1W"], [answer.lookup, answer.work.key]
          assert_equal [[:authors_batch, ["OL1A"]]], client.calls.select { |call| call.first == :authors_batch }
        end

        test "no author records are fetched when the plain check passes" do
          client = FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")]}, works: {"OL1W" => @work})

          Lookup.call(book: @book, client: client)

          assert_not client.calls.any? { |call| call.first == :authors_batch }
        end

        test "an accepted work is checked with its author records too" do
          work = ol_work("OL1W", title: "War and Peace", authors: [["OL1A", "Лев Толстой"]])
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: work),
            authors: {"OL1A" => ol_author("OL1A", name: "Лев Толстой", alternate_names: ["Leo Tolstoy"])})

          assert_equal "OL1W", Lookup.call(book: @book, client: client).work.key
        end

        test "at most RESOLVE_IDENTIFIERS_PER_TYPE values of each identifier type go to /resolve" do
          5.times { |i| ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "978000000000#{i}") }
          5.times { |i| ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "90#{i}") }
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain"))

          Lookup.call(book: @book, client: client)

          args = client.calls.find { |call| call.first == :resolve }.last
          assert_equal [3, 3], [args[:isbn13].size, args[:goodreads_id].size]
        end

        test "an abstain whose top candidate is the stored key and agrees is confirmed with no changes" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_id, value: "OL1W")
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain", work: @work, duplicates: ["OL2W"]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL1W", true, :resolve, [], []], [answer.work.key, answer.confirm_only, answer.lookup, answer.duplicates, answer.redirect_sources]
        end

        test "an abstain whose agreeing top candidate is not the stored key is a second-chance answer, not a confirmation" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_id, value: "OL9W")
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain", work: @work))

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL1W", :resolve_candidate, false], [answer.work.key, answer.lookup, answer.confirm_only]
        end

        test "an abstain whose top candidate is the stored key but fails the check stays unsure" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_id, value: "OL1W")
          other = ol_work("OL1W", title: "Anna Karenina", authors: [["OL1A", "Leo Tolstoy"]])
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain", work: other))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "a decision-level reject never confirms the held top candidate" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_id, value: "OL1W")
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "reject", work: @work))

          answer = Lookup.call(book: @book, client: client)

          assert_equal [nil, false], [answer.work, answer.confirm_only]
        end

        test "an identifier conflict never confirms the held top candidate" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_id, value: "OL1W")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", reason: "identifier conflict on the best candidate: isbn13",
            candidates: [candidate(@work)]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal [nil, false], [answer.work, answer.confirm_only]
        end

        # A tripped volume guard is a refused search: Open Library's candidate
        # list may be short. It says nothing about a key the book holds.
        test "a tripped volume guard still settles on a held top candidate that passes, through held_key" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_id, value: "OL1W")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", volume_guards_tripped: ["author_shelf"],
            candidates: [candidate(@work)]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL1W", :held_key, false], [answer.work&.key, answer.lookup, answer.confirm_only]
        end

        test "a held top candidate with conflicting features is never confirmed" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_id, value: "OL1W")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(@work, conflicts: ["isbn13"])]),
            works: {"OL1W" => @work})

          answer = Lookup.call(book: @book, client: client)

          assert_equal [nil, false], [answer.work, answer.confirm_only]
        end

        def candidate(work, verdict: "abstain", score: 0.9, conflicts: [])
          {work: work, verdict: verdict, score: score, conflicts: conflicts}
        end

        def tolstoy_work(key, title) = ol_work(key, title: title, authors: [["OL1A", "Leo Tolstoy"]])

        test "an abstain whose lower candidate passes our check settles on it" do
          @book.update_columns(title: "The Iliad")
          odyssey = ol_work("OL5W", title: "Ὀδύσσεια", authors: [["OL1A", "Leo Tolstoy"]])
          iliad = ol_work("OL6W", title: "The Iliad", authors: [["OL1A", "Leo Tolstoy"]])
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain",
            candidates: [candidate(odyssey, score: 0.877), candidate(iliad, score: 0.876)]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL6W", :resolve_candidate, false], [answer.work.key, answer.lookup, answer.confirm_only]
          assert_equal "OL5W", answer.ol_pick
        end

        test "other passing candidates are the duplicates" do
          first = tolstoy_work("OL5W", "War and Peace")
          second = tolstoy_work("OL6W", "War and Peace")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(first), candidate(second)]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL5W", ["OL6W"]], [answer.work.key, answer.duplicates]
        end

        # A duplicate key is an identity claim (importers look books up by it):
        # only a work whose full title is ours, not one agreeing without its subtitle.
        test "a candidate with an exact title beats one that passes only without its subtitle, which is no duplicate" do
          subtitled = tolstoy_work("OL5W", "War and Peace: A Novel")
          exact = tolstoy_work("OL6W", "War and Peace")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(subtitled), candidate(exact)]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL6W", []], [answer.work.key, answer.duplicates]
        end

        test "a candidate matching only an alternate title is no duplicate" do
          @book.update_columns(alternate_titles: ["Voina i mir"])
          exact = tolstoy_work("OL5W", "War and Peace")
          alternate = tolstoy_work("OL6W", "Voina i mir")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(exact), candidate(alternate)]))

          assert_equal ["OL5W", []], Lookup.call(book: @book, client: client).then { |answer| [answer.work.key, answer.duplicates] }
        end

        test "a held key that is a passing candidate settles through held_key and keeps its other passing exact-title held keys as duplicates" do
          hold(:books_work_openlibrary_id, "OL5W", :legacy)
          hold(:books_work_openlibrary_id, "OL7W", :legacy)
          hold(:books_work_openlibrary_id, "OL8W", :legacy)
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          top = tolstoy_work("OL4W", "Anna Karenina")
          held = tolstoy_work("OL5W", "War and Peace")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(top), candidate(held)]), works: {
            "OL7W" => tolstoy_work("OL7W", "War and Peace"), "OL8W" => tolstoy_work("OL8W", "War and Peace: A Novel"),
            "OL9W" => tolstoy_work("OL9W", "Anna Karenina")
          })

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL5W", :held_key, ["OL7W"]], [answer.work.key, answer.lookup, answer.duplicates]
        end

        test "a held key that is a reject-band candidate settles through held_key and keeps its other passing exact-title held keys as duplicates" do
          @book.update_columns(title: "Demons")
          hold(:books_work_openlibrary_id, "OL6W", :legacy)
          hold(:books_work_openlibrary_id, "OL7W", :legacy)
          other = tolstoy_work("OL5W", "The Possessed")
          demons = tolstoy_work("OL6W", "Demons")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain",
            candidates: [candidate(other), candidate(demons, verdict: "reject", score: 0.2)]),
            works: {"OL7W" => tolstoy_work("OL7W", "Demons")})

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL6W", :held_key, ["OL7W"]], [answer.work.key, answer.lookup, answer.duplicates]
        end

        test "an accepted work that fails our check gives way to a passing candidate behind it" do
          wrong = tolstoy_work("OL5W", "Anna Karenina")
          right = tolstoy_work("OL6W", "War and Peace")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "accept",
            candidates: [candidate(wrong, verdict: "accept"), candidate(right)]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL6W", :resolve_candidate], [answer.work.key, answer.lookup]
        end

        test "a reject candidate titled exactly like the book settles as exact_title" do
          @book.update_columns(title: "Demons")
          other = tolstoy_work("OL5W", "The Possessed")
          demons = tolstoy_work("OL6W", "Demons")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain",
            candidates: [candidate(other), candidate(demons, verdict: "reject", score: 0.2)]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL6W", :exact_title], [answer.work.key, answer.lookup]
        end

        test "a reject candidate matching only an alternate title is no answer" do
          @book.update_columns(title: "Demons", alternate_titles: ["The Possessed"])
          possessed = tolstoy_work("OL6W", "The Possessed")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain",
            candidates: [candidate(possessed, verdict: "reject", score: 0.2)]))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "an identifier conflict on the best candidate gives no second chance" do
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", reason: "identifier conflict on the best candidate: isbn13",
            candidates: [candidate(tolstoy_work("OL5W", "War and Peace"))]))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "a tripped volume guard gives no second chance" do
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", volume_guards_tripped: ["author_shelf"],
            candidates: [candidate(tolstoy_work("OL5W", "War and Peace"))]))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "a passing candidate with conflicting features is skipped" do
          conflicted = tolstoy_work("OL5W", "War and Peace")
          clean = tolstoy_work("OL6W", "War and Peace")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain",
            candidates: [candidate(conflicted, conflicts: ["isbn13"]), candidate(clean)]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL6W", []], [answer.work.key, answer.duplicates]
        end

        def hold(type, value, source)
          Identifier.create!(identifiable: @book, identifier_type: type, value: value, source: source)
        end

        def abstain_with_nothing = ol_resolution_with(verdict: "abstain", candidates: [])

        test "MAX_WORLDCAT_LOOKUPS is 5" do
          assert_equal 5, Lookup::MAX_WORLDCAT_LOOKUPS
        end

        test "an abstain with no passing candidate settles on a held key whose work passes" do
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          client = FakeOlClient.new(resolution: abstain_with_nothing, works: {"OL9W" => tolstoy_work("OL9W", "War and Peace")})

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL9W", :held_key, [], false], [answer.work.key, answer.lookup, answer.duplicates, answer.confirm_only]
        end

        # One Hundred Years of Solitude: the book held Open Library's main work
        # (Spanish title, 208 editions); the top passing candidate was an
        # English-titled stub with 2. Both pass, so the key the book holds stays.
        test "a passing held key wins over a passing candidate the book does not hold" do
          @book.update_columns(alternate_titles: ["Voina i mir"])
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          stub = tolstoy_work("OL5W", "War and Peace")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(stub)]),
            works: {"OL9W" => tolstoy_work("OL9W", "Voina i mir")})

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL9W", :held_key], [answer.work.key, answer.lookup]
        end

        test "of several passing held keys the exact title wins over stored order" do
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          hold(:books_work_openlibrary_id, "OL8W", :legacy)
          client = FakeOlClient.new(resolution: abstain_with_nothing, works: {
            "OL9W" => tolstoy_work("OL9W", "War and Peace: A Novel"), "OL8W" => tolstoy_work("OL8W", "War and Peace")
          })

          assert_equal "OL8W", Lookup.call(book: @book, client: client).work.key
        end

        test "of several passing held keys with no exact title the oldest identifier wins" do
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          hold(:books_work_openlibrary_id, "OL8W", :legacy)
          client = FakeOlClient.new(resolution: abstain_with_nothing, works: {
            "OL9W" => tolstoy_work("OL9W", "War and Peace: A Novel"), "OL8W" => tolstoy_work("OL8W", "War and Peace: Part One")
          })

          assert_equal "OL9W", Lookup.call(book: @book, client: client).work.key
        end

        test "a held key with no live work is skipped, not the end of the route" do
          hold(:books_work_openlibrary_id, "OL8W", :legacy)
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          client = FakeOlClient.new(resolution: abstain_with_nothing, works: {"OL8W" => nil, "OL9W" => tolstoy_work("OL9W", "War and Peace")})

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL9W", :held_key], [answer.work.key, answer.lookup]
        end

        test "the other passing exact-title held keys are the duplicates" do
          hold(:books_work_openlibrary_id, "OL8W", :legacy)
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          client = FakeOlClient.new(resolution: abstain_with_nothing, works: {
            "OL8W" => tolstoy_work("OL8W", "War and Peace"), "OL9W" => tolstoy_work("OL9W", "War and Peace")
          })

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL8W", ["OL9W"]], [answer.work.key, answer.duplicates]
        end

        test "a held key passing only without its subtitle is no duplicate" do
          hold(:books_work_openlibrary_id, "OL8W", :legacy)
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          client = FakeOlClient.new(resolution: abstain_with_nothing, works: {
            "OL8W" => tolstoy_work("OL8W", "War and Peace: A Novel"), "OL9W" => tolstoy_work("OL9W", "War and Peace")
          })

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL9W", []], [answer.work.key, answer.duplicates]
        end

        test "a held key that is a candidate with conflicting features is not taken" do
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          held = tolstoy_work("OL9W", "War and Peace")
          # not the top candidate, so the earlier confirm-the-stored-key path does not apply
          top = tolstoy_work("OL5W", "Anna Karenina")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(top), candidate(held, conflicts: ["identifier"])]),
            works: {"OL9W" => held})

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "a WorldCat-hit work that is a candidate with conflicting features is not taken" do
          hold(:books_work_isbn13, "9780199232765", :worldcat)
          hit = tolstoy_work("OL5W", "War and Peace")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(hit, conflicts: ["identifier"])]),
            hits: {["isbn13", "9780199232765"] => [ol_hit("OL5W"), ol_hit("OL5W"), ol_hit("OL7W")]}, works: {"OL5W" => hit})

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "a held key whose work fails falls through to the WorldCat ISBNs" do
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          hold(:books_work_isbn13, "9780199232765", :worldcat)
          client = FakeOlClient.new(resolution: abstain_with_nothing,
            hits: {["isbn13", "9780199232765"] => [ol_hit("OL5W"), ol_hit("OL5W"), ol_hit("OL7W")]},
            works: {"OL9W" => tolstoy_work("OL9W", "Anna Karenina"), "OL5W" => tolstoy_work("OL5W", "War and Peace")})

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL5W", :worldcat_isbns], [answer.work.key, answer.lookup]
          # once in the fast pass, once from the WorldCat route
          assert_equal 2, client.calls.count([:identifier, "isbn13", "9780199232765"])
        end

        test "WorldCat ISBNs lead to the work with most hits, the other passing work is a duplicate" do
          hold(:books_work_isbn13, "9780199232765", :worldcat)
          hold(:books_work_isbn10, "0140447938", :worldcat)
          client = FakeOlClient.new(resolution: abstain_with_nothing,
            hits: {
              ["isbn13", "9780199232765"] => [ol_hit("OL6W"), ol_hit("OL5W"), ol_hit("OL5W")],
              ["isbn13", "9780140447934"] => []
            },
            works: {"OL5W" => tolstoy_work("OL5W", "War and Peace"), "OL6W" => tolstoy_work("OL6W", "War and Peace")})

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL5W", ["OL6W"], :worldcat_isbns], [answer.work.key, answer.duplicates, answer.lookup]
        end

        test "a WorldCat work passing only without its subtitle is no duplicate" do
          hold(:books_work_isbn13, "9780199232765", :worldcat)
          client = FakeOlClient.new(resolution: abstain_with_nothing,
            hits: {["isbn13", "9780199232765"] => [ol_hit("OL5W"), ol_hit("OL5W"), ol_hit("OL6W")]},
            works: {"OL5W" => tolstoy_work("OL5W", "War and Peace"), "OL6W" => tolstoy_work("OL6W", "War and Peace: A Novel")})

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL5W", [], :worldcat_isbns], [answer.work.key, answer.duplicates, answer.lookup]
        end

        test "an ISBN-10 held only as ISBN-10 is looked up in its ISBN-13 form" do
          hold(:books_work_isbn10, "0199535566", :worldcat)
          client = FakeOlClient.new(resolution: abstain_with_nothing)

          Lookup.call(book: @book, client: client)

          # the fast pass looks it up as an ISBN-10; only the WorldCat route asks for the ISBN-13 form
          assert_equal [1, 1], [client.calls.count([:identifier, "isbn10", "0199535566"]), client.calls.count([:identifier, "isbn13", "9780199535569"])]
        end

        test "a WorldCat work that fails the check is no answer" do
          hold(:books_work_isbn13, "9780199232765", :worldcat)
          client = FakeOlClient.new(resolution: abstain_with_nothing,
            hits: {["isbn13", "9780199232765"] => [ol_hit("OL5W")]}, works: {"OL5W" => tolstoy_work("OL5W", "Anna Karenina")})

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "legacy-source ISBNs are never looked up by the WorldCat route" do
          hold(:books_work_isbn13, "9780199232765", :legacy)
          client = FakeOlClient.new(resolution: abstain_with_nothing)

          Lookup.call(book: @book, client: client)

          # the fast pass looks it up once; the WorldCat route must not add a second
          assert_equal 1, client.calls.count([:identifier, "isbn13", "9780199232765"])
        end

        test "no more than MAX_WORLDCAT_LOOKUPS ISBNs are looked up by the WorldCat route" do
          %w[9780000000019 9780000000026 9780000000033 9780000000040 9780000000057 9780000000064 9780000000071].each do |isbn|
            hold(:books_work_isbn13, isbn, :worldcat)
          end
          client = FakeOlClient.new(resolution: abstain_with_nothing)

          Lookup.call(book: @book, client: client)

          # fast pass: 5 of 8 identifiers; the WorldCat route: 5 of 7
          assert_equal 10, client.calls.count { |call| call.first == :identifier }
        end

        test "an identifier conflict stops the held-key and WorldCat routes" do
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          hold(:books_work_isbn13, "9780199232765", :worldcat)
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", reason: "identifier conflict on the best candidate: isbn13",
            candidates: []), hits: {["isbn13", "9780199232765"] => [ol_hit("OL5W"), ol_hit("OL5W"), ol_hit("OL7W")]},
            works: {"OL9W" => tolstoy_work("OL9W", "War and Peace"), "OL5W" => tolstoy_work("OL5W", "War and Peace")})

          assert_nil Lookup.call(book: @book, client: client).work
          assert_equal 1, client.calls.count([:identifier, "isbn13", "9780199232765"])
        end

        # Frankenstein, The Iliad, The Aeneid in the dev rehearsal: every one
        # tripped author_shelf, and each held a passing work with hundreds of editions.
        test "a tripped volume guard does not stop the held-key route" do
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", volume_guards_tripped: ["author_shelf"],
            candidates: []), works: {"OL9W" => tolstoy_work("OL9W", "War and Peace")})

          assert_equal ["OL9W", :held_key], Lookup.call(book: @book, client: client).then { |answer| [answer.work&.key, answer.lookup] }
        end

        test "a tripped volume guard does not stop the WorldCat route" do
          hold(:books_work_isbn13, "9780199232765", :worldcat)
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", volume_guards_tripped: ["author_shelf"], candidates: []),
            # Two works, so the fast pass does not settle on its own.
            hits: {["isbn13", "9780199232765"] => [ol_hit("OL5W"), ol_hit("OL5W"), ol_hit("OL7W")]}, works: {"OL5W" => tolstoy_work("OL5W", "War and Peace")})

          assert_equal ["OL5W", :worldcat_isbns], Lookup.call(book: @book, client: client).then { |answer| [answer.work&.key, answer.lookup] }
        end

        # Dead Souls in the dev rehearsal: the held work (218 editions) was a
        # conflicted candidate, so held_key skipped it, and the book's WorldCat
        # ISBNs led to a 2-edition duplicate. Moving there loses editions.
        test "no route moves a book off a passing held work onto one with fewer editions" do
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          hold(:books_work_isbn13, "9780199232765", :worldcat)
          held = ol_work("OL9W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]], editions: 218)
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(held, verdict: "reject", score: 0.3, conflicts: ["identifier"])]),
            hits: {["isbn13", "9780199232765"] => [ol_hit("OL5W"), ol_hit("OL5W"), ol_hit("OL7W")]},
            works: {"OL9W" => held, "OL5W" => ol_work("OL5W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]], editions: 2)})

          assert_nil Lookup.call(book: @book, client: client).work
        end

        # Tristram Shandy: the held work had 1 edition, the ISBNs' work 85.
        test "a route may move a book off a passing held work onto one with more editions" do
          hold(:books_work_openlibrary_id, "OL9W", :legacy)
          hold(:books_work_isbn13, "9780199232765", :worldcat)
          held = ol_work("OL9W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]], editions: 1)
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(held, verdict: "reject", score: 0.3, conflicts: ["identifier"])]),
            hits: {["isbn13", "9780199232765"] => [ol_hit("OL5W"), ol_hit("OL5W"), ol_hit("OL7W")]},
            works: {"OL9W" => held, "OL5W" => ol_work("OL5W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]], editions: 85)})

          assert_equal ["OL5W", :worldcat_isbns], Lookup.call(book: @book, client: client).then { |answer| [answer.work&.key, answer.lookup] }
        end

        test "a tripped volume guard still stops the candidate routes" do
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", volume_guards_tripped: ["author_shelf"],
            candidates: [candidate(tolstoy_work("OL5W", "War and Peace")), candidate(tolstoy_work("OL6W", "War and Peace"), verdict: "reject", score: 0.2)]))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "a decision-level reject stops the WorldCat route" do
          hold(:books_work_isbn13, "9780199232765", :worldcat)
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "reject", candidates: []),
            hits: {["isbn13", "9780199232765"] => [ol_hit("OL5W"), ol_hit("OL6W")]},
            works: {"OL5W" => tolstoy_work("OL5W", "War and Peace")})

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "a reject candidate titled exactly like the book but by another author is no answer" do
          @book.update_columns(title: "Demons")
          stranger = ol_work("OL6W", title: "Demons", authors: [["OL7A", "Somebody Else"]])
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain",
            candidates: [candidate(stranger, verdict: "reject", score: 0.2)]))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "a reject candidate whose subtitle makes its full title longer is no exact title" do
          @book.update_columns(title: "Demons")
          subtitled = ol_work("OL6W", title: "Demons", subtitle: "A Novel in Three Parts", authors: [["OL1A", "Leo Tolstoy"]])
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain",
            candidates: [candidate(subtitled, verdict: "reject", score: 0.2)]))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "the highest-scoring qualifying reject candidate wins, whatever the service order" do
          @book.update_columns(title: "Demons")
          lower = tolstoy_work("OL5W", "Demons")
          higher = tolstoy_work("OL6W", "Demons")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain",
            candidates: [candidate(lower, verdict: "reject", score: 0.30), candidate(higher, verdict: "reject", score: 0.35)]))

          assert_equal "OL6W", Lookup.call(book: @book, client: client).work.key
        end

        test "a decision-level reject gives no second chance" do
          @book.update_columns(title: "Demons")
          demons = tolstoy_work("OL6W", "Demons")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "reject",
            candidates: [candidate(demons, verdict: "reject", score: 0.2)]))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "the exact-title preference also follows an alternate title" do
          @book.update_columns(alternate_titles: ["Voina i mir"])
          subtitled = tolstoy_work("OL5W", "Voina i mir: roman")
          exact = tolstoy_work("OL6W", "Voina i mir")
          client = FakeOlClient.new(resolution: ol_resolution_with(verdict: "abstain", candidates: [candidate(subtitled), candidate(exact)]))

          assert_equal "OL6W", Lookup.call(book: @book, client: client).work.key
        end

        test "a confident accept is not a confirm_only answer" do
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: @work))

          assert_equal false, Lookup.call(book: @book, client: client).confirm_only
        end

        test "any other Open Library error is raised" do
          client = FakeOlClient.new(errors: [::Books::OpenLibrary::Exceptions::ServerError.new("boom", 500)])

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { Lookup.call(book: @book, client: client) }
        end
      end
    end
  end
end
