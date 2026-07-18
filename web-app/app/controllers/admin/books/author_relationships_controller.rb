class Admin::Books::AuthorRelationshipsController < Admin::Books::BaseController
  before_action :set_author_relationship, only: [:update, :destroy]

  def create
    @author = ::Books::Author.find(params[:author_id])
    authorize @author, :update?, policy_class: ::Books::AuthorPolicy
    @author_relationship = @author.author_relationships.build(author_relationship_params)

    if @author_relationship.save
      respond_to do |format|
        format.turbo_stream { render_author_relationships("Relationship added.") }
        format.html { redirect_to admin_books_author_path(@author), notice: "Relationship added." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@author_relationship) }
        format.html { redirect_to admin_books_author_path(@author), alert: @author_relationship.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    @author = @author_relationship.from_author
    authorize @author, :update?, policy_class: ::Books::AuthorPolicy

    if @author_relationship.update(author_relationship_params)
      respond_to do |format|
        format.turbo_stream { render_author_relationships("Relationship updated.") }
        format.html { redirect_to admin_books_author_path(@author), notice: "Relationship updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@author_relationship) }
        format.html { redirect_to admin_books_author_path(@author), alert: @author_relationship.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @author = @author_relationship.from_author
    authorize @author, :update?, policy_class: ::Books::AuthorPolicy
    @author_relationship.destroy!

    respond_to do |format|
      format.turbo_stream { render_author_relationships("Relationship removed.") }
      format.html { redirect_to admin_books_author_path(@author), notice: "Relationship removed." }
    end
  end

  private

  def set_author_relationship
    @author_relationship = ::Books::AuthorRelationship.find(params[:id])
  end

  def author_relationship_params
    params.require(:books_author_relationship).permit(:to_author_id, :relation_type)
  end

  def render_author_relationships(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("author_relationships_list", partial: "admin/books/authors/author_relationships_list", locals: {author: @author})
    ]
  end

  def render_association_error(record)
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: record.errors.full_messages.join(", ")}}
    ), status: :unprocessable_entity
  end
end
