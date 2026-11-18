# Built on the machine and imported straight into k3s containerd by
# `gitops build gpu-queue`. There is no registry here, which is why the
# Deployment sets imagePullPolicy: Never.
FROM python:3.12-slim

# No compiler needed: every dependency ships a manylinux wheel, asyncpg
# included. Keeping build-essential out saves roughly 300 MB.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Unprivileged. The only thing it writes is the job manifest directory,
# which is mounted and owned accordingly.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin queue
USER 10001

EXPOSE 4100

# One worker, deliberately. The admission counters live in memory, so a
# second worker would admit up to the limit independently and the card
# would see twice what either process believes it allowed.
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", "--port", "4100", \
     "--workers", "1", \
     "--timeout-keep-alive", "75", \
     "--no-access-log"]
