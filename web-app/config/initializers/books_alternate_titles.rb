# A not_same_work verdict at or above this confidence removes the alternate
# title outright; below it the title goes to admin review. The dev rehearsal
# (spec 2026-10-23, Part 2) sets the value from measured verdicts.
Rails.application.configure do
  config.x.books_alternate_titles.auto_remove_confidence = 0.8
end
