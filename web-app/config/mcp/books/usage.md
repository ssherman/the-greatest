# Using The Greatest Books tools

Answer only from what the tools return. Do not fill gaps from memory.

- Cite each book you mention with its `url` from the tool result, so the person can open its page on the site.
- Keep rank order. Collections of ranked books come best first, and a lower `rank` is better. Present them in that order and do not re-sort them.
- Check `total_count` in `meta`. When it is larger than the number of items you fetched, say so, for example "these are the top 50 of 1,200", and use the `page` and `limit` arguments if you need more.
- Report only ranks you fetched, and never invent a rank. If a book's `rank` is null, it is not ranked, and you should say that. If you did not fetch a rank, do not guess it.

For a question about one book, `find_book` returns the book and the lists that include it in one call. Use `search_books` first when the title is ambiguous. The `ranking-methodology` resource explains how lists are weighted into the ranking, what a ranking configuration is and what `rank` means; read it before answering a question about why a book ranks where it does.
