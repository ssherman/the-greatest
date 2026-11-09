"""Statement rank, as `wdt:` reads it."""


def best_rank(statements: list[dict]) -> list[dict]:
    """The preferred statements if any exist, else the normal ones; never deprecated."""
    for rank in ("preferred", "normal"):
        chosen = [s for s in statements if s.get("rank", "normal") == rank]
        if chosen:
            return chosen
    return []
