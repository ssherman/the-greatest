# frozen_string_literal: true

class Admin::Categories::TableComponent < ViewComponent::Base
  def initialize(categories:, pagy:, domain_config:)
    @categories = categories
    @pagy = pagy
    @domain_config = domain_config
  end

  private

  attr_reader :categories, :pagy, :domain_config

  def sort_path(column)
    "#{domain_config[:categories_path]}?sort=#{column}&q=#{CGI.escape(helpers.params[:q].to_s)}"
  end

  def category_path(category)
    domain_config[:category_path_proc].call(category)
  end

  def edit_category_path(category)
    domain_config[:edit_category_path_proc].call(category)
  end
end
