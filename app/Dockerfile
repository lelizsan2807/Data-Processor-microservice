FROM python:3.10-slim

WORKDIR /app

COPY app.py .
COPY entrypoint.sh .

RUN chmod 755 entrypoint.sh

USER 2048:2048

ENTRYPOINT ["./entrypoint.sh"]
