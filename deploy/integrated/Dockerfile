FROM python:3.11-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY server/requirements.txt /app/requirements.txt
RUN pip install --disable-pip-version-check -r requirements.txt
COPY server/ /app/
RUN useradd --create-home --uid 10001 trade && chown -R trade:trade /app
USER trade
EXPOSE 8787
CMD ["uvicorn", "riskon.asgi:application", "--host", "0.0.0.0", "--port", "8787", "--workers", "1", "--proxy-headers", "--forwarded-allow-ips", "*"]
