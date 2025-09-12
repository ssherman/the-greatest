# == Schema Information
#
# Table name: external_links
#
#  id              :bigint           not null, primary key
#  click_count     :integer          default(0), not null
#  description     :text
#  link_category   :integer
#  metadata        :jsonb
#  name            :string           not null
#  parent_type     :string           not null
#  price_cents     :integer
#  public          :boolean          default(TRUE), not null
#  source          :integer
#  source_name     :string
#  url             :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  parent_id       :bigint           not null
#  submitted_by_id :bigint
#
# Indexes
#
#  index_external_links_on_click_count                (click_count)
#  index_external_links_on_parent                     (parent_type,parent_id)
#  index_external_links_on_parent_type_and_parent_id  (parent_type,parent_id)
#  index_external_links_on_public                     (public)
#  index_external_links_on_source                     (source)
#  index_external_links_on_submitted_by_id            (submitted_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (submitted_by_id => users.id)
#
class ExternalLink < ApplicationRecord
  belongs_to :parent, polymorphic: true
  belongs_to :submitted_by, class_name: "User", optional: true

  enum :source, {
    amazon: 0,
    goodreads: 1,
    bookshop_org: 2,
    musicbrainz: 3,
    discogs: 4,
    wikipedia: 5,
    other: 6
  }, prefix: true

  enum :link_category, {
    product_link: 0,
    review: 1,
    information: 2,
    misc: 3
  }, prefix: true

  validates :name, presence: true
  validates :url, presence: true, format: URI::DEFAULT_PARSER.make_regexp(%w[http https])
  validates :price_cents, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
  validates :source_name, presence: true, if: :source_other?
  validates :click_count, numericality: {only_integer: true, greater_than_or_equal_to: 0}

  scope :public_links, -> { where(public: true) }
  scope :by_source, ->(source) { where(source: source) }
  scope :by_category, ->(category) { where(link_category: category) }
  scope :most_clicked, -> { order(click_count: :desc) }

  def increment_click_count!
    increment!(:click_count)
  end

  def display_price
    return nil unless price_cents

    "$#{"%.2f" % (price_cents / 100.0)}"
  end

  def source_display_name
    source_other? ? source_name : source.humanize
  end

  def trackable_url
    Rails.application.routes.url_helpers.external_link_redirect_url(self)
  end
end
