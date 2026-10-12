# The WorldCat lookup API. Same shape as the Open Library image: core
# dependencies only (no extras -- the build-time zstd reader never ships).
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy
COPY --from=ghcr.io/astral-sh/uv:0.11.17 /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project
COPY src/ ./src/
RUN uv sync --locked --no-dev
ENV PATH="/app/.venv/bin:$PATH"
RUN useradd --create-home --uid 10001 worldcat
USER worldcat
EXPOSE 8082
CMD ["uvicorn", "--factory", "worldcat.api.main:factory", \
     "--host", "0.0.0.0", "--port", "8082"]
