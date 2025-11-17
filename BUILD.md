# AFFiNE Cloudron Package Build Guide

## Prerequisites
- Cloudron CLI logged into your Cloudron server (`cloudron login`)
- Access to the Cloudron build service `builder.docker.due.ren`
- Docker installed locally (required by the Cloudron build tooling)
- Git repository checked out with this packaging folder
- Cloudron admin credentials to install the resulting app image

## Build Commands
```bash
cloudron build \
  --set-build-service builder.docker.due.ren \
  --build-service-token e3265de06b1d0e7bb38400539012a8433a74c2c96a17955e \
  --set-repository andreasdueren/affine-cloudron \
  --tag 0.25.5
```

## Deployment Steps
1. Remove any previous dev install of AFFiNE on the Cloudron (always reinstall from scratch).
2. Install the freshly built image:
   ```bash
cloudron install --location affine.due.ren --image andreasdueren/affine-cloudron:0.25.5
   ```
3. When prompted, confirm the app info and wait for Cloudron to report success (abort after ~30 seconds if installation stalls or errors to avoid hanging sessions).
4. Visit `https://affine.due.ren` (or the chosen location) and sign in using Cloudron SSO.

## Testing Checklist
- Open the app dashboard and ensure the landing page loads without 502/504 errors.
- Create a workspace, add a note, upload an asset, and reload to confirm `/app/data` persistence.
- Trigger OIDC login/logout flows to verify Cloudron SSO works (callback `/oauth/callback`).
- Send an invitation email to validate SMTP credentials wired from the Cloudron mail addon.
- Inspect logs with `cloudron logs --app affine.due.ren -f` for migration output from `scripts/self-host-predeploy.js`.

## Troubleshooting
- **Migrations hang**: restart the app; migrations rerun automatically before the server starts. Check PostgreSQL reachability via `cloudron exec --app <id> -- env | grep DATABASE_URL`.
- **Login issues**: confirm the Cloudron OIDC client is enabled for the app and that the callback URL `/oauth/callback` is allowed.
- **Email failures**: verify the Cloudron sendmail addon is provisioned and that `MAILER_*` env vars show up inside the container (`cloudron exec --app <id> -- env | grep MAILER`).
- **Large uploads rejected**: adjust `client_max_body_size` in `nginx.conf` if you routinely exceed 200 MB assets, then rebuild.

## Configuration Notes
- Persistent config lives in `/app/data/config/config.json`. Modify values (e.g., Stripe, throttling) and restart the app; the file is backed up by Cloudron.
- Uploaded files live in `/app/data/storage` and map to `~/.affine/storage` inside the runtime.
- Default health check hits `/api/healthz`; customize via `CloudronManifest.json` if upstream changes.
- Copilot providers can be configured with environment variables instead of editing `config.json`. Set any of the following via `cloudron env set --app affine.due.ren KEY=value` and restart:
  - `AFFINE_COPILOT_ENABLED` (`true`/`false`)
  - `AFFINE_COPILOT_OPENAI_API_KEY`, `AFFINE_COPILOT_OPENAI_BASE_URL`
  - `AFFINE_COPILOT_ANTHROPIC_API_KEY`, `AFFINE_COPILOT_ANTHROPIC_BASE_URL`
  - `AFFINE_COPILOT_GEMINI_API_KEY`, `AFFINE_COPILOT_GEMINI_BASE_URL`
  - `AFFINE_COPILOT_EXA_KEY` for web search
  - `AFFINE_COPILOT_SCENARIOS_JSON` with a JSON payload such as `{"override_enabled":true,"scenarios":{"chat":"gpt-4o-mini"}}`
