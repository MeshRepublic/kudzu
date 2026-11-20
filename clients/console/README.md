# Kudzu Console

Terminal client (Textual) for the Kudzu governance and brain APIs.

## Install

```
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'
```

## Run

```
export KUDZU_HOST=http://100.70.67.110:4001
export KUDZU_API_KEY=...
.venv/bin/kudzu
```

Other environment variables: `OLLAMA_HOST`, `SEARXNG_HOST`, `ANTHROPIC_API_KEY`.

## tmux clipboard

Details to be completed in a later task.
