# A not_same_work verdict at or above this confidence removes the alternate
# title outright; below it the title goes to admin review. Set from the dev
# rehearsal of 2026-10-23 (spec 2026-10-23, Part 2): at 0.8, "other work"
# removals between 0.80 and 0.90 included real translations the model did not
# recognise ("Die Eisprinzessin schläft", "Junger Mond", the Ukrainian
# "Artemis Fowl"); at 0.9 and above they were almost all right.
Rails.application.configure do
  config.x.books_alternate_titles.auto_remove_confidence = 0.9
end
