# == Schema Information
#
# Table name: books_publisher_intake_runs
#
#  id          :bigint           not null, primary key
#  baseline    :boolean          default(FALSE), not null
#  counts      :jsonb            not null
#  error       :text
#  finished_at :datetime
#  kind        :integer          default("weekly"), not null
#  source      :string           not null
#  started_at  :datetime         not null
#  status      :integer          default("running"), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_books_publisher_intake_runs_on_source_and_started_at  (source,started_at)
#
module Books
  # One discovery pass for one source (publisher intake design §1). counts keys
  # (strings): "requests", "outstanding", "listings_seen", "listings_new",
  # "listings_changed".
  class PublisherIntakeRun < ApplicationRecord
    enum :kind, {weekly: 0, manual: 1}, prefix: true
    enum :status, {running: 0, finished: 1, failed: 2}, prefix: true

    scope :for_source, ->(key) { where(source: key) }

    validates :source, presence: true
    validates :started_at, presence: true
  end
end
