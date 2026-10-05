# frozen_string_literal: true

module Books
  module Goodreads
    # Whether a Goodreads page backs an edition (Goodreads import spec §6,
    # "Agreement"): its main title is the edition's, and a contributor who may
    # be its author has the edition's primary author's name.
    #
    # Lenient on purpose. A false mismatch parks a real book from a member's
    # library; a false agreement creates a provisional book an admin reviews
    # anyway. Measured 2026-10-04: it agreed with the catalog's title and
    # author on all 19 real pages, "Miguel de Cervantes" against "Miguel de
    # Cervantes Saavedra" included.
    #
    # On a verified page the authors of a new book are the name that agreed
    # and the page's creators; a name with no role never becomes an author.
    class Agreement
      Verdict = Data.define(:outcome, :author_names)

      def self.call(edition:, page:)
        new(edition: edition, page: page).call
      end

      def initialize(edition:, page:)
        raise ArgumentError, "Goodreads page #{page.goodreads_book_id} is not an answer (#{page.outcome})" unless page.conclusive?

        @edition = edition
        @page = page
      end

      def call
        return verdict(:not_found) if @page.outcome_not_found?
        return verdict(:mismatch) unless same_title?(@edition.title, @page.title)

        named = @page.contributors.find { |contributor| credited?(contributor) && same_person?(@edition.primary_author, contributor.name) }
        return verdict(:mismatch) if named.nil?

        creators = @page.contributors.select(&:creator?).map(&:name)
        Verdict.new(outcome: :verified, author_names: [named.name, *creators].uniq)
      end

      private

      # The primary contributor is whom an export names as Author, whatever the
      # role (an anthology's editor); a contributor with no role may be one.
      def credited?(contributor)
        contributor.primary || contributor.role.nil? || contributor.creator?
      end

      def same_title?(mine, theirs)
        mine = main_title(mine)
        mine.present? && mine == main_title(theirs)
      end

      # Normalized, without a series suffix or a subtitle, punctuation dropped.
      def main_title(title)
        ExportRow.normalize(title).sub(BookPage::SERIES_SUFFIX, "").split(":").first.to_s
          .gsub(/[^\p{L}\p{N}]+/, " ").strip
      end

      # One name's words are all in the other: a fuller or shorter form of the
      # same name.
      def same_person?(mine, theirs)
        mine = tokens(mine)
        theirs = tokens(theirs)
        return false if mine.empty? || theirs.empty?

        shorter, longer = [mine, theirs].sort_by(&:size)
        (shorter - longer).empty?
      end

      def tokens(name) = ExportRow.normalize(name).gsub(/[^\p{L}\p{N}]+/, " ").split.uniq

      def verdict(outcome) = Verdict.new(outcome: outcome, author_names: [])
    end
  end
end
