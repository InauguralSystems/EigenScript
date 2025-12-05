# EigenScript Web Playground

Interactive web interface for running EigenScript code in the browser.

## Quick Start (Local)

```bash
cd web
pip install -r requirements.txt
python app.py
```

Visit http://localhost:5000

## Deploy to Railway

1. Connect your GitHub repo to [Railway](https://railway.app)
2. Set the root directory to `web/`
3. Railway auto-detects the Procfile and deploys

## Deploy to Render

1. Connect your GitHub repo to [Render](https://render.com)
2. Create a new Web Service
3. Set:
   - Root Directory: `web`
   - Build Command: `pip install -r requirements.txt`
   - Start Command: `gunicorn app:app`

## Deploy to Fly.io

```bash
cd web
fly launch
fly deploy
```

## Features

- **Code Editor**: Write and edit EigenScript code
- **Example Gallery**: Pre-loaded examples demonstrating language features
- **Live Execution**: Run code with 30-second timeout
- **Keyboard Shortcuts**: Ctrl/Cmd + Enter to run

## Examples Included

| Example | Description |
|---------|-------------|
| Hello World | Basic syntax introduction |
| Convergence | The "Inaugural Algorithm" - damped oscillation |
| Factorial | Recursive function demo |
| XOR Demo | Neural network-style computation |
| Matrix Operations | Linear algebra with matrices |
| Higher-Order Functions | map, filter, reduce |
| Geometric Introspection | Self-aware predicates |

## API Endpoints

- `GET /` - Playground UI
- `POST /run` - Execute code (JSON: `{code: "..."}`)
- `GET /examples/<name>` - Get example code

## Environment

The playground requires EigenScript to be installed. For cloud deployment,
the `requirements.txt` includes eigenscript as a dependency.
