# frozen_string_literal: true

# The user-list CSV, moved from MyListsController without changing its output
# (spec §9): test/controllers/my_lists_controller_test.rb pins the bytes.
# Columns vary per listable; the Completed On column appears only on lists
# whose list_type supports a completion date. Uncapped -- a list is the
# viewer's own data, or data someone chose to make public.
#
# Model constants are root-anchored where they could be shadowed: inside
# CsvExports a bare UserList is this class.
module CsvExports
  class UserList
    def self.call(list:, items:, io: StringIO.new)
      new(list, items).write(io)
    end

    def initialize(list, items)
      @list = list
      @items = items
      @listable_name = list.class.listable_class.name
      @show_completed = list.completed_on_enabled?
    end

    def write(io)
      writer = Writer.new(io, headers: headers)
      @items.each { |item| writer.row(row(item)) }
      io
    end

    private

    def headers
      headers =
        case @listable_name
        when "Music::Album", "Music::Song" then ["Position", "Title", "Artists", "Year"]
        when "Books::Book" then ["Position", "Title", "Authors", "Year"]
        else ["Position", "Title", "Year"]
        end
      @show_completed ? headers + ["Completed On"] : headers
    end

    def row(item)
      listable = item.listable
      row =
        case @listable_name
        when "Music::Album", "Music::Song"
          [item.position, listable.title, artist_names(listable), listable.release_year]
        when "Books::Book"
          [item.position, listable.title, author_names(listable), listable.first_published_year]
        else
          [item.position, listable.title, listable.release_year]
        end
      @show_completed ? row + [item.completed_on&.iso8601] : row
    end

    def artist_names(listable)
      listable.artists.map(&:name).join(", ")
    end

    def author_names(listable)
      listable.book_authors.map { |book_author| book_author.author.name }.join(", ")
    end
  end
end
