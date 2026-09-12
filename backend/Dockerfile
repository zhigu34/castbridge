FROM python:3.12-slim

ARG PYPI_INDEX_URL=https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_INDEX_URL=${PYPI_INDEX_URL} \
    UV_DEFAULT_INDEX=${PYPI_INDEX_URL}

RUN pip install --no-cache-dir uv

WORKDIR /app/backend
COPY backend/pyproject.toml ./pyproject.toml
RUN uv sync --no-dev --no-install-project

COPY backend/app ./app

ENV PATH="/app/backend/.venv/bin:${PATH}"

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
