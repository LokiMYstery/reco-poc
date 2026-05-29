FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV POC_SEMANTIC=none
ENV POC_SQLITE_PATH=/app/data/poc_music_scene.db
ENV POC_PREFERENCE_PATH=/app/data/poc_preference.json

WORKDIR /app

COPY requirements_runtime.txt .
RUN pip install --no-cache-dir -r requirements_runtime.txt

COPY . .
RUN mkdir -p /app/data

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import json, urllib.request; data=json.load(urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)); raise SystemExit(0 if data.get('ok') is True else 1)"

CMD ["uvicorn", "poc_api:app", "--host", "0.0.0.0", "--port", "8000"]
