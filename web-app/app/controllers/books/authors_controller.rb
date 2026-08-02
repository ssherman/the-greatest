class Books::AuthorsController < ApplicationController
  layout "books/application"

  def show
    @author = Books::Author.find_by!(slug: params[:slug])
  end
end
