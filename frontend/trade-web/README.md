# TradeTools Web terminal

This React/Vite frontend is the integrated copy of `/Users/apple/work/trade-web`.
The UI and analysis components stay in place while data comes from the Django
backend in `../../server`:

- `/api/auth/*` uses the shared iOS account and JWT access token.
- `/api/web/settings` stores versioned per-user page preferences.
- `/api/market/*` and `/ws/v1` use the shared market stream and K-line history.

Run locally with an ASGI Django server on port 8000, then run `npm install` and
`npm run dev`. The Vite proxy handles `/api` and `/ws`. Production builds use
`/market/`; the runtime resolves the `/integrated/` prefix when deployed beside
the integrated API.

`npm test` runs deterministic analysis, preference, and request lifecycle tests;
`npm run build` creates a static bundle with relative asset paths so it can be
served below `/integrated/market/`.
