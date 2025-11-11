module ApplicationHelper
  include Pagy::Frontend

  def format_duration(seconds)
    return "—" if seconds.nil? || seconds == 0

    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    secs = seconds % 60

    if hours > 0
      "%d:%02d:%02d" % [hours, minutes, secs]
    else
      "%d:%02d" % [minutes, secs]
    end
  end
end
