# Reco POC

Recommendation system proof-of-concept workspace.

## Structure

```text
backend/   FastAPI + SQLite music scene recommendation POC
frontend/  Swift/iOS sensor-style frontend POC workspace
_docs/     (none)
docs/      Integration and payload contract documentation
```

## Backend quick start

```bash
cd backend
python3 -m pip install -r requirements_poc.txt
uvicorn poc_api:app --host 0.0.0.0 --port 8000
```

Health check:

```bash
curl http://127.0.0.1:8000/health
```

Backend smoke:

```bash
cd backend
python3 smoke_backend.py --base-url http://127.0.0.1:8000
```

Docker on a VPS:

```bash
cd backend
docker compose up -d --build
curl http://127.0.0.1:8000/health
```

## Frontend contract

See `docs/frontend-backend-payload-contract.md`.
