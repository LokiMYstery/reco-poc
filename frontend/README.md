# Frontend POC

This folder is reserved for the Swift/iOS sensor-style frontend POC.

The frontend's main job is to collect observable user context and feedback events, then call the backend APIs:

- `POST /v1/recommend`
- `POST /v1/feedback`

See `../docs/frontend-backend-payload-contract.md` for the current payload contract.
