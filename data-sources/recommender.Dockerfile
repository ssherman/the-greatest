# The collaborative-filtering trainer (spec 2026-10-09-book-recommendations-collaborative).
# Its own image so the Open Library API never carries numpy/scipy, and this
# one never carries DuckDB's data or a browser. Runs as a one-shot job.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

COPY --from=ghcr.io/astral-sh/uv:0.11.17 /uv /uvx /bin/

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --extra recommender --no-install-project

COPY src/ ./src/
RUN uv sync --locked --no-dev --extra recommender

ENV PATH="/app/.venv/bin:$PATH"

RUN useradd --create-home --uid 10001 recommender \
 && mkdir -p /work && chown recommender /work
USER recommender

ENTRYPOINT ["python", "-m", "recommender.cli"]
CMD ["run"]
