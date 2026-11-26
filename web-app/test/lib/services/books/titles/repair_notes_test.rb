# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Titles
      class RepairNotesTest < ActiveSupport::TestCase
        setup do
          @author = ::Books::Author.create!(name: "Rowan Hale")
        end

        def book(title, subtitle = nil, author: @author)
          record = ::Books::Book.create!(title: title, subtitle: subtitle)
          ::Books::BookAuthor.create!(book: record, author: author, position: 1)
          record
        end

        def parts(record) = record.reload.then { |r| [r.title, r.subtitle] }

        test "a title cut inside its brackets is joined back up" do
          cut = book("Accounting 2 (Quick Study", "Business)")

          RepairNotes.call

          assert_equal ["Accounting 2 (Quick Study: Business)", nil], parts(cut)
        end

        test "a closing series or format note comes off the title and the subtitle" do
          titled = book("BOOM goes the Bride (Brides of Nap City Book 1)")
          subtitled = book("Forging Worlds", "A Mini Guide (Step by Step Worldbuilding Book 8)")
          rejoined = book("Lady of Terras (The Vayde Chronicles", "Book 1)")
          tagged = book("Teresa de Jesús (Spanish Edition)")
          dangling = book("The Flash", "Hocus Pocus: (The Flash Book 1)")

          RepairNotes.call

          assert_equal [["BOOM goes the Bride", nil], ["Forging Worlds", "A Mini Guide"], ["Lady of Terras", nil], ["Teresa de Jesús", nil],
            ["The Flash", "Hocus Pocus"]],
            [titled, subtitled, rejoined, tagged, dangling].map { |record| parts(record) }
        end

        test "a bracket that may say which book this is stays" do
          kept = ["Theology (Volume 2)", "The Iliad (Classics Illustrated)", "Accounting 2 (Quick Study: Business)"].map { |title| book(title) }

          assert_equal 0, RepairNotes.call.data[:changed]
          assert_equal kept.map(&:title), kept.map { |record| record.reload.title }
        end

        test "the note stays when the author has another book under the title without it" do
          book("Rising")
          noted = book("Rising (Night Watch, Book 2)")
          other = book("Rising (Night Watch, Book 2)", author: ::Books::Author.create!(name: "Someone Else"))

          RepairNotes.call

          assert_equal ["Rising (Night Watch, Book 2)", "Rising"], [noted, other].map { |record| record.reload.title }
        end

        test "a dry run reports the changes and saves nothing" do
          noted = book("BOOM goes the Bride (Brides of Nap City Book 1)")

          result = RepairNotes.call(dry_run: true)

          assert_equal [{id: noted.id, from: ["BOOM goes the Bride (Brides of Nap City Book 1)", nil], to: ["BOOM goes the Bride", nil]}],
            result.data[:changes]
          assert_equal "BOOM goes the Bride (Brides of Nap City Book 1)", noted.reload.title
        end

        test "a second run changes nothing, and the slug stays" do
          noted = book("BOOM goes the Bride (Brides of Nap City Book 1)")
          slug = noted.slug

          assert_equal 1, RepairNotes.call.data[:changed]
          assert_equal [0, slug], [RepairNotes.call.data[:changed], noted.reload.slug]
        end
      end
    end
  end
end
