import pytest


@pytest.fixture
def anyio_backend():
    # The service runs on asyncio under uvicorn; async tests run there only.
    return "asyncio"
