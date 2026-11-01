FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:0.9.5 /uv /uvx /bin/
COPY requirements.txt /tmp/requirements.txt
RUN uv pip install --system --no-cache --requirements /tmp/requirements.txt \
    && useradd --uid 10001 --create-home --shell /usr/sbin/nologin prime

WORKDIR /app
COPY --chown=10001:10001 app.py fingerprint.py /app/
COPY --chown=10001:10001 data/catalog.json /app/data/catalog.json

ENV PYTHONUNBUFFERED=1
USER 10001
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
