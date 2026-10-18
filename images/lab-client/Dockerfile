# The lab client: predict and bench commands, run with kubectl exec. Build from the repository root:
#   docker build -f images/lab-client/Dockerfile -t lab723/lab-client:1.0.0 .
# The prepare life cycle action runs it with "sleep infinity", and its probes check that predict and bench are on
# the PATH. The guardrail demo in Exercise 2 also uses this image.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY app/common/samples.py app/lab-client/labclient.py /app/
RUN printf '#!/bin/sh\nexec python3 /app/labclient.py predict "$@"\n' > /usr/local/bin/predict \
 && printf '#!/bin/sh\nexec python3 /app/labclient.py bench "$@"\n' > /usr/local/bin/bench \
 && chmod 755 /usr/local/bin/predict /usr/local/bin/bench \
 && useradd --uid 10001 --create-home --shell /usr/sbin/nologin lab
USER 10001
CMD ["sleep", "infinity"]
