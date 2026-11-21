class Admin::Books::ListsController < Admin::ListsBaseController
  include Admin::DomainScopedAuth

  AUDIT_FILTERS = %w[not_audited verified unverifiable in_progress].freeze

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

  def list_audits? = true

  def audit_filter
    params[:audit].presence_in(AUDIT_FILTERS)
  end

  def apply_extra_filters(scope)
    case audit_filter
    when "not_audited" then scope.where.not(id: ::ListAudit.done.select(:list_id))
    when "verified" then scope.where(id: ::ListAudit.latest_done.verified.select(:list_id))
    when "unverifiable" then scope.where(id: ::ListAudit.latest_done.unverifiable.select(:list_id))
    when "in_progress" then scope.where(id: ::ListAudit.open.select(:list_id))
    else scope
    end
  end

  def items_count_name = "books_count"

  def listable_includes = [:authors]

  # A generated list has no wizard: its generator writes its items.
  def wizard_path(list) = list.auto_generated? ? nil : admin_books_list_wizard_path(list_id: list.id)
end
