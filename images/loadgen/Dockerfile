# The load generator for Exercise 4. Build from the repository root:
#   docker build -f images/loadgen/Dockerfile -t lab723/loadgen:1.0.0 .
# The Python process is PID 1, which the deployment's probes check with "kill -0 1".
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY app/common/samples.py app/loadgen/loadgen.py /app/
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin lab
USER 10001
CMD ["python3", "/app/loadgen.py"]
