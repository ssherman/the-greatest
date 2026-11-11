module Admin::RankingArchivesHelper
  def archive_origin_label(archive)
    archive.origin.to_s.capitalize
  end

  # The monthly job recreates the current month's archive on its next run, so
  # deleting it is pointless; say so instead of the generic warning.
  def archive_delete_confirmation(archive)
    if archive.period.present? && archive.period == Time.now.utc.to_date.beginning_of_month
      "This is this month's automatic archive. If you delete it, tomorrow's run creates it again. Hide it instead to keep it off the site."
    else
      "Delete this archive? This cannot be undone."
    end
  end
end
