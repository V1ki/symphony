# Symphony History Detail v2 Design Spec

## Deliverables

- `01-overview.png` - 1920 x 1200 overview mockup.
- `02-tool-call-card.png` - 1280 x 720 exec_command card states.
- `03-apply-patch-diff.png` - 1280 x 720 apply_patch diff renderer.
- `04-token-and-reasoning.png` - 1280 x 720 token and reasoning states.
- `05-interactions.png` - 1920 x 1080 search, filters, and keyboard interaction model.

## Design Intent

### 01-overview.png

The overview establishes the first viewport of `/history/<session_id>` as a session-reading surface, not a dense log dump. The hero summarizes what happened, the summary cards make turn count, tool usage, and token load scannable, the left turn timeline gives fast orientation by turn time, and the main event stream groups related calls with outputs. Long first user messages are collapsed by default, copy actions are ghost icons that appear on hover or selection, and turn duration is placed as a time-derived metric beside each turn instead of relying on `duration_ms`.

### 02-tool-call-card.png

The exec command card shows the same object in collapsed, hover, and expanded states so implementation can preserve hierarchy without adding repeated green copy buttons. The command itself is the strongest visual anchor via `cmd-chip`; metadata stays compact; hover reveals the ghost copy control; expanded mode uses two columns for args and output so operators can compare input and result without scrolling through a single preformatted block.

### 03-apply-patch-diff.png

The patch renderer converts `apply_patch` payloads into explicit file operations: `patch-add`, `patch-update`, and `patch-delete`. Add and delete cards use restrained diff color blocks, while update uses a two-column before/after diff with line numbers and hunk context. The goal is to make add/update/delete recognizable at a glance and eliminate raw `<pre>{inspect}</pre>` map dumps.

### 04-token-and-reasoning.png

Token information is shown as trend and context pressure instead of isolated numbers. The `sparkline` shows token evolution across turns, token_count events are inline rows with deltas and context usage, and the `reasoning-card` has collapsed and expanded treatments that keep reasoning available without letting it dominate the event stream. Turn duration placement is again shown as a time-range-derived value.

### 05-interactions.png

The interaction mockup documents the fast navigation layer: top search, filter chips, visible selected event state, ghost copy on the active card, and keyboard hints. The screen should feel usable with keyboard only: `/` focuses search, `j` and `k` move selection, `space` expands or collapses the selected event, and `c` copies the active event or visible command/output block.

## Key Interactions

- `j`: move selection to the next visible event after filters and search are applied. The selected event receives a clear focus ring and is scrolled into view only when needed.
- `k`: move selection to the previous visible event after filters and search are applied.
- `space`: expand or collapse the selected event. For a collapsed tool call, expand the paired call/output card. For long text, expand from preview to the medium or full state.
- `c`: copy the selected event's primary value. For tool calls, copy the command when collapsed and copy the focused args/output pane when expanded. The copy control is a ghost icon visible on hover or selected state, never a repeated green button.
- `/`: focus the top search field. Search filters visible events and highlights matches inside event titles, command chips, filenames, and message previews.
- Filter chips: chips are multi-select toggles. Required chips are `All`, `User`, `Assistant`, `Tool calls`, `Errors`, `Tokens`, `Patches`, and `Reasoning`. `All` clears other chips; choosing any specific chip disables `All`.
- Long text thresholds: text over 200 characters renders as `long-text-collapsed` with a 200-character preview and fade. Text over 800 characters keeps the default collapsed state and expands first to an 800-character medium view, then to full text via a secondary "show full" affordance.
- Function call pairing: `function_call` and `function_call_output` with the same call id render inside one card. Missing output keeps a pending state; missing call context marks the output as orphaned but still uses the same tool-call visual shell.
- Turn duration: do not surface `duration_ms` when it is zero. Show turn time as `started_at - ended_at` or a derived elapsed value from adjacent turn timestamps.

## Color Tokens

- `accent`: `#EA7A1A`
- `accent-soft`: `#F8D8BC`
- `surface`: `#F9F9F7`
- `page-bg`: `#F6F4EE`
- `text`: `#1F2933`
- `text-muted`: `#536273`
- `border`: `#DED8CA`
- `border-strong`: `#B9B0A0`
- `diff-add`: `#E8F5DF`
- `diff-add-text`: `#275B32`
- `diff-del`: `#FDE7DF`
- `diff-del-text`: `#8A3324`
- `focus`: `#2F5D75`
- `success-minimal`: `#DCEED8`

## Spacing And Shape

- Padding uses only `8px`, `12px`, and `16px` for cards, rows, chips, and panels.
- Gaps use only `8px` and `12px` inside cards and event groups.
- `border-radius` is `8px` for cards, panels, chips, inputs, and buttons.
- Shadows should be minimal: prefer borders and background contrast. Use at most a very soft elevation on the selected or hovered card.
- Monospace font is limited to command strings, args, output, diff content, file paths, and keyboard keycaps.
- Copy affordances are icon-only ghost controls with hover or selected visibility.

## Required Self-Verification Markers

The coding task must render HTML containing these class markers:

- `call-card-collapsed`
- `patch-add`
- `patch-update`
- `patch-delete`
- `cmd-chip`
- `reasoning-card`
- `sparkline`
- `long-text-collapsed`

Suggested additional markers for easier testing:

- `call-card-expanded`
- `call-card-hover`
- `turn-timeline`
- `event-selected`
- `filter-chip`
- `token-count-inline`
- `copy-ghost`
- `turn-time-duration`

## Acceptance Checks For Implementation

- No visible repeated green copy buttons in the event stream.
- The initial long user message is collapsed by default when it exceeds 200 characters.
- Paired `function_call` and `function_call_output` events share one visual card.
- `apply_patch` displays add, update, and delete operations without raw map dumps.
- Search and filter chips operate before keyboard selection.
- Token values include a sparkline or inline delta treatment, not only static numbers.
- Turn duration area uses turn timestamps or derived elapsed time when `duration_ms` is zero.
