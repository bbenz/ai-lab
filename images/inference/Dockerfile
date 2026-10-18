# The inference service, on the CPU. Build from the repository root:
#   docker build -f images/inference/Dockerfile -t lab723/inference:1.0.0 .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    INFERENCE_DEVICE=cpu \
    MODEL_CACHE_DIR=/tmp/model \
    OTEL_SERVICE_NAME=inference \
    OTEL_PYTHON_FASTAPI_EXCLUDED_URLS="healthz,ready,metrics"

WORKDIR /app
COPY app/inference/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY app/inference/server.py /app/server.py

# Not distroless on purpose: the lab runs cat in this container to read its CPU throttling counters.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin app
USER 10001
EXPOSE 8080
CMD ["python", "-m", "uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
