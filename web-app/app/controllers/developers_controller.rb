# frozen_string_literal: true

# GET /developers -- the public API's documentation.
#
# Global route with a per-domain layout (PagesController's shape). Edge-cached
# for a day: the page renders the same bytes for every visitor. Nothing here
# reads current_user, and DevelopersControllerTest proves the content is
# identical signed in and out, because one per-visitor byte on a cached page
# is served to everyone.
#
# The endpoint reference is built from the OpenAPI document for THIS host, so
# it cannot drift from the contract and the music host never documents
# /api/v1/books. Api::Problem#to_h points its `type` URI at this page's
# #errors-<code> anchors; the test pins every code to one.
class DevelopersController < ApplicationController
  include Cacheable
  include DomainLayout

  layout :resolve_layout

  before_action :cache_for_show_page
  before_action :mark_indexable

  Operation = Struct.new(:method, :path, :operation_id, :summary, :description, :parameters, :statuses, :public, keyword_init: true)

  def show
    @base_url = Api::Host.base_url
    @document = Api::OpenapiDocument.for_host(@base_url, domain: Current.domain)
    @operations = operations_for(@document)
    @rate_limits = Rails.application.config.x.api.rate_limits
    @unauthenticated_per_minute = Rails.application.config.x.api.unauthenticated_per_minute
    @example_url = example_url
  end

  private

  # See PagesController#mark_indexable: the three sites' robots helpers have
  # opposite defaults, so a public page must say so explicitly.
  def mark_indexable
    @indexable = true
  end

  # One row per (method, path). `$ref` parameters are named by the last path
  # segment of the reference (#/components/parameters/page -> "page").
  def operations_for(document)
    document.fetch("paths").flat_map do |path, item|
      item.except(Api::OpenapiDocument::DOMAIN_KEY).map do |method, operation|
        Operation.new(
          method: method.upcase,
          path: path,
          operation_id: operation.fetch("operationId"),
          summary: operation["summary"],
          description: operation["description"],
          parameters: Array(operation["parameters"]).map { |parameter| parameter["$ref"]&.split("/")&.last || parameter["name"] },
          statuses: operation.fetch("responses").keys,
          public: operation["security"] == []
        )
      end
    end
  end

  # The quick-start example calls the first authenticated endpoint on this
  # host. A site with none yet (music and games until their resources ship)
  # shows the books call, which the same token works on.
  def example_url
    first = @operations.find { |operation| !operation.public }
    return "#{@base_url}#{first.path}" if first

    "#{Api::Host.base_url(:books)}/api/v1/books"
  end
end
