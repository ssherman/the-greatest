class Admin::Books::ListsController < Admin::ListsBaseController
  include Admin::DomainScopedAuth

  private

  def policy_class = ::Books::ListPolicy

  def item_label = "Book"

  protected

  def list_class = ::Books::List

  def lists_path = admin_books_lists_path

  def list_path(list) = admin_books_list_path(list)

  def new_list_path = new_admin_books_list_path

  def edit_list_path(list) = edit_admin_books_list_path(list)

  def param_key = :books_list

  def items_count_name = "books_count"

  def listable_includes = [:authors]

  # A generated list has no wizard: its generator writes its items.
  def wizard_path(list) = list.auto_generated? ? nil : admin_books_list_wizard_path(list_id: list.id)
end
