# Symphony History Detail Design Spec

## Scope

This design package is for the Symphony `/history/<session_id>` detail page. It is based on the real session file `rollout-2026-05-02T08-57-41-019de630-f421-71e3-aa8c-642e292dee9e.jsonl`, whose useful pressure points are 93 tool calls, 78 token count events, long first prompt content, and many paired tool outputs. The goal is a clean trace reader for implementation work, not a marketing page and not a code prototype.

The visual direction is a quiet developer operations UI: warm beige page background, off-white panels, slate text, warm orange emphasis, blue-gray borders, and very limited green only for successful diff lines. Copy actions should be ghost icon buttons that appear on hover or focus. The page should avoid dense green rectangular buttons and should keep code in monospace while all navigation, labels, metrics, and explanations use system-ui.

## 01-overview.png

The overview shows the intended first viewport at 1920x1200. The top hero carries the issue identity, title, Teambition link, status badge, model/version metadata, and a compact summary strip. The summary area should include duration, total tokens with sparkline, cached percentage, model, and total tool calls. The main structural decision is the sticky left sidebar. It acts as a turn navigator, not a decorative timeline: each turn row shows time, event count, and a tiny distribution bar for user messages, reasoning, assistant messages, tool calls, patch calls, and token events. Clicking a turn should scroll the main event stream to that turn and keep the selected turn visually anchored.

The main column renders the selected turn as an event stream with compact rows by default. Long user prompts, especially the AGENTS.md bootstrap text, must be collapsed on first paint. Reasoning is also collapsed by default. Assistant messages stay readable as normal cards. Tool calls are grouped and paired with outputs so the user can understand "what ran and what came back" without scanning separate raw JSON events.

## 02-tool-call-card.png

This image defines the exec_command card behavior. The collapsed row is the normal state for dense sessions: one line shows the chevron, command summary, duration, and output size. Hover and keyboard focus reveal a small ghost copy icon in the top-right area; it should never become a large colored button. Expanded state uses a clear two-column comparison: args on the left, output on the right. The command string is the visual anchor and should be larger than other metadata. Workdir, session id, method, and timing are secondary.

Output rendering uses line numbers and clipped terminal content. Large output should default to a bounded height with a `show all (N lines)` affordance. Exit code and duration sit in the footer so a reader can scan success/failure without expanding every card. This card is the template for `teambition_api`, `write_stdin`, and `update_plan`, with tool-specific metadata substituted into the args column.

## 03-apply-patch-diff.png

`apply_patch` must render as diff, never as a raw map, JSON blob, or preformatted inspect dump. The patch mini-map on the left indexes multiple patch calls inside a long session and should be clickable. Each patch block header shows operation type, relative path from cwd, and line delta. `Add File` is a single green diff column with line numbers. `Update File` uses a two-column search/replace layout: red removed lines and gray context on the left, green added lines and gray context on the right. `Delete File` is a single red diff column with deleted-line styling.

Every apply_patch card should include a small ghost `Open in workspace` action. The target can be a `file://` URL for the affected path when it is inside the workspace. This is intentionally a secondary control; the key information remains operation, path, and changed lines.

## 04-token-and-reasoning.png

Token data should explain when cost accumulated, not just display a large total. The chart uses turns on the x axis and cumulative tokens on the y axis, with separate lines for input, cached input, output, and reasoning. The inline token_count treatment belongs inside the turn divider or turn summary bar, not as a standalone card, because token events are context for the surrounding work.

Reasoning is a distinct event type. Its default rendering is a one-line collapsed row such as `Codex thinking · 234 words · 2s`. When expanded, it should use markdown styling, gray background, and calm spacing. Assistant messages should remain visually separate from reasoning so the page does not mix private thinking-style trace content with user-facing summaries.

## 05-interactions.png

The interaction sheet annotates the behavior expected from the final implementation. The sidebar remains sticky during scroll and still indicates the selected turn near the bottom of the page. Keyboard navigation should support `j` and `k` for previous/next event, `space` for expand/collapse, `c` for copying the focused event content, and `/` for global search. The global search box highlights matching event rows and should keep enough context around each match to avoid a jumpy experience.

Tool filter chips reduce the event stream to one tool family, such as `exec_command`, while preserving turn context. Filters should be reversible and should not destroy the current scroll anchor. Search and filters can work together: filter first, then search within the visible subset. Apply_patch cards expose `Open in workspace` at the card level because the natural next action after reading a diff is inspecting the file.

## Implementation Notes For The Next Agent

Use a master/detail reading model without forcing a separate route: left side navigates turns, main stream shows events, and expanded cards provide detail in place. Pair `function_call` and `function_call_output` by `call_id` before rendering. Parse `custom_tool_call` named `apply_patch` into operations and hunks before it reaches the template. Collapse text blocks above 800 characters and show a 200 character preview. Keep visible Chinese labels sparse and stable; the mockups intentionally use only a few Chinese navigation labels to avoid visual noise and image-generation artifacts.

Acceptance for implementation should be based on scan speed: a user should identify the current turn, the commands that ran, their outputs, token spikes, and file edits without reading raw event maps.
