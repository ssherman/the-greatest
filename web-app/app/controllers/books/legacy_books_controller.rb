class Books::LegacyBooksController < ApplicationController
  # find_by!(id:), never find: Books::Book uses friendly_id with :finders, which
  # resolves slugs before primary keys. 124 books have a purely numeric slug that
  # matches a different book's id, so .find here would redirect to the wrong book.
  def show
    book = Books::Book.find_by!(id: params[:id])

    redirect_to book_path(book.slug), status: :moved_permanently
  end
end
