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


## iOS frontend install

```bash
git pull origin main
open frontend/RecoPOC/RecoPOC.xcodeproj
```

In Xcode, select the `RecoPOCHost` scheme, choose a physical iPhone, confirm the signing team under **Signing & Capabilities**, then press **Run**. After the app installs, open the in-app Setup screen first to grant the requested sensor permissions and complete the questionnaire before starting a recommendation run. The committed backend URL defaults to `https://www.zkjpoc.icu`; override `RECO_BACKEND_BASE_URL` only when targeting a local or staging backend. Real sensor capture should be validated on a physical device, not the simulator.

## Frontend contract

See `docs/frontend-backend-payload-contract.md`.
