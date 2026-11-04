# How the ranking works

The Greatest Books does not rank books by its own opinion. It combines lists. The site holds curated lists of books, and a ranking turns the active ones into a single ordering. A book rises by appearing on many lists and by sitting high on the lists it is on. Each list has a weight, and a list with more weight moves the books on it further. Lists that are not active are left out, and so is any list entry that has not been matched to a book in the catalogue.

The calculation is tuned by a ranking configuration, a named set of the settings it uses. The main ones are an exponent, 3.0 by default, which shapes the curve the scores follow; a bonus pool percentage, 3.0 by default, the share of the total score pool set aside for bonuses; and the date penalty settings.

The date penalty compares the year a list was published with the year a book first appeared. When both years are known it can reduce what a list entry contributes. By default the penalty is at most 80 percent. A book released in or after the year of the list gets the full penalty, an older book gets less as the gap grows, and a book more than 50 years older than the list gets none. Each configuration holds its own figures.

A ranking configuration is also the frame for two numbers in the results. A list's `weight` is its weight on one configuration, and it is null when the list does not feed that configuration. A book's `rank` is its position on one configuration. The site publishes one primary book ranking. Unless you ask for another configuration, `rank` and `weight` refer to the primary one, and `list_ranking_configurations` shows which others exist.

`rank` is a position counted from 1. Rank 1 is the best book on that ranking, and it is null when a book is not ranked. Collections of ranked books arrive best first, so their order is the rank order, and you should keep it when you present them.

Rankings are recalculated in the background after changes such as merged records. Automatic triggers wait about five minutes so that a burst of changes is handled in one run, so a rank can lag the latest edit slightly.

These notes do not say how a list's weight is chosen. Read the `weight` the list tools return, and do not estimate one. To see why a book ranks where it does, look at the lists it appears on and the weight of each, which `find_book` and `list_book_lists` return.
