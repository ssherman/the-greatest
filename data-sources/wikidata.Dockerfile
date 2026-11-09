# The Wikidata lookup API and its build. One image, two compose services: the API
# runs uvicorn; wikidata-build overrides the command with the pipeline. The
# `wikidata` extra is the build's dump reader (isal, orjson, pyyaml); the API
# needs them too, because it reads kept.yml. No other extra ships.
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy
COPY --from=ghcr.io/astral-sh/uv:0.11.17 /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --extra wikidata --no-install-project
COPY src/ ./src/
RUN uv sync --locked --no-dev --extra wikidata
ENV PATH="/app/.venv/bin:$PATH"
RUN useradd --create-home --uid 10001 wikidata
USER wikidata
EXPOSE 8083
CMD ["uvicorn", "--factory", "wikidata.api.main:factory", \
     "--host", "0.0.0.0", "--port", "8083"]
