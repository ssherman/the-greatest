# frozen_string_literal: true

namespace :images do
  desc "Enqueue Images::AnalyzeDimensionsJob for Image covers whose blob has no width (safe to re-run; production only)"
  task analyze_missing_dimensions: :environment do
    ids = ActiveStorage::Blob
      .joins(:attachments)
      .where(active_storage_attachments: {record_type: "Image", name: "file"})
      .where("active_storage_blobs.metadata::jsonb ->> 'width' IS NULL")
      .distinct
      .pluck(:id)

    jobs = 0
    ids.each_slice(500) do |slice|
      Images::AnalyzeDimensionsJob.perform_async(slice)
      jobs += 1
    end

    puts "#{ids.size} blobs missing dimensions, #{jobs} jobs enqueued"
  end
end
