class Books::LegacyAuthorsController < ApplicationController
  # find_by!(id:), never find: Books::Author uses friendly_id with :finders,
  # which resolves slugs before primary keys.
  def show
    author = Books::Author.find_by!(id: params[:id])

    redirect_to author_path(author.slug), status: :moved_permanently
  end
end
