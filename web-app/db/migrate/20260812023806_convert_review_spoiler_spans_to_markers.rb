class ConvertReviewSpoilerSpansToMarkers < ActiveRecord::Migration[8.1]
  # Runs during db:prepare in bin/docker-entrypoint, BEFORE rails server starts
  # serving. That ordering is the point: the render change in this same deploy drops
  # `span` from the render allowlist, so any row still storing a spoiler span at the
  # moment traffic arrives would print its spoiler in the clear.
  #
  # A local model class, not ::Review -- a migration has to keep working when the app's
  # model changes underneath it. update_columns skips validations and callbacks, so
  # BodySanitizer never runs against a body mid-conversion.
  class MigrationReview < ActiveRecord::Base
    self.table_name = "reviews"
  end

  def up
    say_with_time "Converting stored spoiler spans to markers" do
      converted_count = 0

      MigrationReview.where("body LIKE ?", "%review-spoiler%").find_each do |review|
        converted = Services::Reviews::SpoilerSpanConverter.call(review.body)
        next if converted == review.body

        review.update_columns(body: converted)
        converted_count += 1
      end

      converted_count
    end
  end

  # Irreversible by design: the markers are the canonical form now, and reversing would
  # regenerate markup the write path can no longer produce.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
