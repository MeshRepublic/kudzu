# Kudzu Console

The Kudzu Console is a terminal application for working with a Kudzu server: chat with the brain and other backends, evaluate proposed laws against the constitution, try the Antitrust 2.0 rule on a scenario, and read the weight ledger. It has four views (Chat, Proposals, Antitrust, Ledger) and runs in any terminal, including over SSH and inside tmux.

It needs a running Kudzu server that exposes the `/api/v1/governance` routes. It replaces the older `kudzu_chat.py`.

## Install

Python 3.12 or newer is required. Install into a virtualenv, never into system Python. From the repository root:

```
python3 -m venv clients/console/.venv
clients/console/.venv/bin/pip install -e clients/console
```

Run it with the venv's script (or activate the venv and type `kudzu`):

```
export KUDZU_HOST=http://<kudzu-host>:4001
export KUDZU_API_KEY=<your-api-key>
clients/console/.venv/bin/kudzu
```

## Configuration

All settings are environment variables, read once at start-up.

| Variable | Default | Used for |
|---|---|---|
| `KUDZU_HOST` | `http://100.70.67.110:4001` | Base URL of the Kudzu server (all views and the header status). |
| `KUDZU_API_KEY` | empty | Bearer key sent to the Kudzu server. Without a valid key the governance calls are refused. |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server for the `Ollama: ...` chat backends. |
| `SEARXNG_HOST` | `http://localhost:8888` | SearXNG server for the `Web (SearXNG)` chat backend. |
| `ANTHROPIC_API_KEY` | empty | Key for the `Claude API` chat backend. |
| `KUDZU_CLIPBOARD` | unset | Set to `local` to copy with a program on this machine instead of OSC 52 (see Copying text). |

Trailing slashes on the host URLs are removed. Keep keys out of files you commit.

## The views

The header line shows the server host, the number of holograms, the model, and the silo counts as `expertise/rejection/contested` (`silos: empty ⚠` when the expertise silo is empty). It refreshes every 15 seconds.

**Chat.** A sidebar lists the backends: Kudzu Brain (on by default), several Ollama models, Web (SearXNG) and Claude API. Space toggles a backend; each enabled backend answers in turn. Enter sends the message. The sidebar also shows the tier, tool-call count and cost of the last Kudzu Brain answer. Only one message can be in flight at a time.

**Proposals.** Type or paste a proposed law (Shift+Enter or Ctrl+J adds a line; pasted text keeps its lines), pick a constitutional principle and press Evaluate (or Enter in the text box). The server runs the proposal through five stages, shown as five rows: direct rejection match, accumulated weight, expertise match, AI judge, decision. Each row has an outcome and detail numbers; stages that were never reached are dimmed with a dash. The result is headed by the proposal text and principle the server evaluated, which stay on screen while you edit the text box. Above the rows is the verdict: permitted, denied, denied by accumulated weight, `PERMITTED WITH WEIGHT ... needs a vote`, or `CANNOT EVALUATE`. `Cannot evaluate` means the server could not reach a decision; the reason it gave is printed under the headline. The banner `Judge only — no distilled Constitution loaded` appears when the server reports empty silos, meaning no distilled Constitution is loaded and only the AI judge stage can decide. When the verdict needs a vote, Vote yes and Vote no are enabled. One vote is allowed per proposal: the buttons are disabled as soon as one is pressed, and a proposal already voted on stays closed. Proposals evaluated in this session are listed in a history pane on the right when the terminal is at least 140 columns wide; select one to show it again.

**Antitrust.** Fill in a scenario (company and vertical are optional; market share, baseline and current satisfaction, and the two limits are required numbers) or press a preset: Triggered, Watch, Not triggered, Boundary. The limits start at 40% share and 10% satisfaction drop and are replaced by the server's own defaults once they load. Press Evaluate; the server decides, and the result panel shows one of three results:

- `TRIGGERED` — both metrics are met: market share at or above the share limit, and a satisfaction drop at or beyond the drop limit.
- `WATCH` — one metric is met.
- `NOT TRIGGERED` — neither is met.

Below the headline are a concentration line and a satisfaction line, each marked ✓ if that metric is met and ✗ if not. Editing any field clears the shown result.

**Ledger.** A read-only view of ratified weights. At the top is one total per principle, shown as `principle  total / threshold`, where the threshold is the server's tau_A (accumulated-weight threshold). Totals over the threshold are highlighted (red, bold) and listed first. Select a total to filter the entries to that principle; select it again to clear the filter. Below is the table of entries (time in UTC, principle, weight, proposal id, anchor status); select a column header to sort, and again to reverse. The proposal id column is hidden when the terminal is narrower than 80 columns. The ledger reloads each time the view is shown and after every successful vote.

## Keys

| Key | Action |
|---|---|
| F1, F2, F3, F4 | Chat, Proposals, Antitrust, Ledger (clicking a tab also works) |
| Ctrl+K | Command palette |
| Ctrl+Q | Quit |

Command palette commands: `status`, `progress`, `traces`, `clear`, `quit`. The first four act on the Chat view's conversation.

In the chat input: Enter sends; Shift+Enter or Ctrl+J adds a new line; Up and Down at the first or last line walk through messages you sent earlier; Tab moves between the sidebar and the input. Slash commands typed in the input:

- `/status` — brain status from the server.
- `/progress` — the brain's progress report.
- `/traces [purpose] [count]` — recent traces; count defaults to 5.
- `/clear` — empty the conversation.
- `/quit` (or `/exit`) — leave the app.

The old app's `/copy`, `/help` and `/growth` are not part of this app.

## Copying text

Highlight text with the mouse (drag over it); it is copied when you release the button. The footer then shows `copied (osc52)` or `copied (local)` for two seconds.

By default the copy uses the OSC 52 terminal escape sequence, so it reaches the clipboard of the machine you are sitting at, even over SSH. The app cannot detect whether your terminal supports OSC 52; it assumes so.

**tmux.** tmux must pass the sequence on. Add this to `~/.tmux.conf` and restart tmux (or run `tmux set -g set-clipboard on`):

```
set -g set-clipboard on
```

**Local programs.** To copy with a program on the machine the console runs on instead of OSC 52, set `KUDZU_CLIPBOARD=local`. The console then pipes the text into the first of these that is installed: `wl-copy`, `xclip -selection clipboard`, `pbcopy`. This is only useful when that machine is the one you are sitting at.

**Terminal's own selection.** Hold Shift while dragging to use the terminal's own selection; the app never sees it, and you copy with your terminal's usual shortcut.

If no copy method worked, the footer shows `copy failed — hold Shift and drag to use the terminal's selection`.

## Running the tests

```
clients/console/.venv/bin/pip install -e 'clients/console[dev]'
clients/console/.venv/bin/pytest clients/console/tests
```

## Troubleshooting

**The header says `disconnected ✗ (...)`.** The word in parentheses says why.

- `unreachable`: the console could not connect to `KUDZU_HOST` (wrong address, server down, Tailscale not up, or a timeout). Check the URL, for example with `curl "$KUDZU_HOST/health"`.
- A 401 or 403 (missing or invalid key, or a key without the needed scope): the word is the server's own error message, for example `Invalid API key`. Check `KUDZU_API_KEY`.
- `server_error` or `http_error`: the server answered with an error status and no error message of its own.
- `bad_response`: the server answered, but not in the shape the console expects.
- `error`: an unexpected failure inside the console.

**The principle list in Proposals is empty,** and Evaluate stays disabled. The principles come from the governance status call; the view shows `principles could not be loaded` and retries each time you switch to it. Fix the connection or key as above, then press F2 again.

**Copy does nothing in tmux.** Check that `set -g set-clipboard on` is in effect (`tmux show -g set-clipboard`) and that your outer terminal allows OSC 52. If it does not, set `KUDZU_CLIPBOARD=local`, or hold Shift and drag to use the terminal's own selection.
