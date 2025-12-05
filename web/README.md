# EigenScript Web Playground

Interactive web interface for running EigenScript code with full language support.

## Deploy to Replit (Recommended)

1. Import this repo to Replit
2. Set the run directory to `web/`
3. Click **Run** - Replit auto-detects the config

The `replit.nix` includes LLVM toolchain for full compiler support.

## Local Development

```bash
cd web
pip install -r requirements.txt
python app.py
```

Visit http://localhost:5000

## Deploy with Docker

```bash
cd web
docker build -t eigenscript-playground .
docker run -p 5000:5000 eigenscript-playground
```

## Deploy to Railway/Render

1. Connect your GitHub repo
2. Set root directory to `web/`
3. Auto-deploys from Dockerfile

## Features

- **Full EigenScript v0.4.1** - Complete language support
- **10 Example Programs** - Demonstrating all major features
- **Geometric Introspection** - Self-aware predicates (converged, stable, etc.)
- **Matrix Operations** - Linear algebra support
- **Higher-Order Functions** - map, filter, reduce
- **Meta-Circular Evaluation** - Self-reference demos
- **Keyboard Shortcuts** - Ctrl+Enter to run, Tab for indent

## Examples Included

| Example | Description |
|---------|-------------|
| Hello World | Basic syntax |
| Convergence | The Inaugural Algorithm |
| Factorial | Recursive functions |
| XOR Neural Net | Threshold activation |
| Matrix Operations | Linear algebra |
| Attention Mechanism | Transformer core |
| Higher-Order Functions | map/filter/reduce |
| Geometric Introspection | Self-aware predicates |
| Interrogatives | WHO/WHAT/WHERE queries |
| Meta-Circular Eval | Self-reference stability |

## API Endpoints

- `GET /` - Playground UI
- `POST /run` - Execute code `{code: "...", mode: "interpret"}`
- `GET /examples/<name>` - Get example code
- `GET /health` - Health check

## Files

```
web/
├── app.py              # Flask server
├── templates/
│   └── index.html      # Playground UI
├── requirements.txt    # Python dependencies
├── Dockerfile          # Container deployment
├── Procfile           # Heroku/Railway
├── .replit            # Replit config
└── replit.nix         # Nix dependencies
```
