# The branch leader's playbook

A branch leader is a crewmate that briefs, steers and supervises up to four crewmates of its own on one epic, and reports to First Mate the way any crewmate does.
This page is what a leader does at each of its moments and which script does the reading; the scripts' headers own their exact flags.
Two words hold everywhere: the leader measures its crewmates from the outside and never asks them to, and nothing it builds stops, throttles or warns a crewmate.

## What a leader is

- A leader is spawned as one: `bin/fm-spawn.sh ... --leads` records `leads=1` and leaves the harness's own trim line in place, because the epic's whole shape lives in the leader's head.
- A leader is briefed as one: `bin/fm-brief.sh <leader-id> <repo> --mode <mode> --leads` (or `--scout --leads`) adds "# You lead crewmates" after the doors, whose first sentence is "Read docs/branch-leader.md before your first steer", with this page's path.
  That sentence is how a leader finds this page: no other generated brief names it, and a `--leads` spawn whose brief lacks it is launched with a warning, never refused.
- Its crewmates are spawned under it: `bin/fm-spawn.sh ... --leader <leader-id>` records `leader=<leader-id>` in each crewmate's task record ([`bin/fm-lead-lib.sh`](../bin/fm-lead-lib.sh) owns the chain).
  The chain is one level deep: a led crewmate cannot lead, and a leader takes four crewmates at once; the spawn refuses a fifth, naming the four.
- Each crewmate's brief is scaffolded with the same leader: `bin/fm-brief.sh <id> <repo> --mode <mode> --leader <leader-id>` names the leader as the one who answers the crewmate's doors, and the spawn refuses a brief and a `--leader` that disagree ([`bin/fm-brief.sh`](../bin/fm-brief.sh) header).
- While a leader exists, First Mate's channel to a working crewmate carries lifecycle and the captain's words only, never the work.
  That is built into [`bin/fm-send.sh`](../bin/fm-send.sh), not written down for First Mate to remember: to a crewmate whose leader holds a live agent, fm-send refuses plain text, typed text and an answer to a door, and prints the leader's steer command, unless the send carries one mark - `--from-leader <leader-id>` (the leader's own steer, which `fm-lead.sh steer` and `trim` pass), `--captain` (the captain's words, already appended verbatim to the brief's Captain's intent), or `--lifecycle <relaunch|teardown|handover|escalation>`; each mark is recorded in the inbox record's header.
  `--key` stays open, and a dead leader reopens the channel.
- The leader keeps its own logbook, `data/<leader-id>/logbook.md`, for the epic's shape, its open steers and its pending splits; First Mate reads it when it watches the branch.

## The crewmate's two doors

A led crewmate's brief gives it exactly two reasons to surface before its story is done, both keyed status lines:

- `needs-decision: [key=story-size] {the two halves}` before it begins, when the story is two stories.
  Split, or hold the line with the reason and re-brief; the crewmate is the last check on the leader's cut.
- `blocked: [key=stuck] {what it tried, what it sees}` when it is looping or drifting.
  Answer in one steer, or escalate to First Mate.

Each door reaches the leader's own inbox the moment the crewmate's turn ends: the crewmate's Stop hook runs [`bin/fm-lead-relay.sh`](../bin/fm-lead-relay.sh), which puts two lines into the leader's steering inbox, `door: <crewmate-id> <verb> [key=<key>] <note>` and the exact steer that closes it, and records the ring in the crewmate's door ledger, `data/<crewmate-id>/doors/index`.
While the leader holds a door, First Mate is not woken for it: the watcher absorbs that crewmate's door line and its turn-end for as long as the leader's endpoint is alive and the door is open, and First Mate still sees the open door in every drain's open-decisions section.
First Mate is woken for the door, once, when it has stayed open 30 minutes (`FM_LEADER_ESCALATE_SECS`, 1,800 by default), at once when the leader has died holding it, and at once when the ring could not reach the leader or the crewmate's status carries anything else First Mate must see ([`bin/fm-watch.sh`](../bin/fm-watch.sh) header, "the chain").
So a door is the leader's to answer within the half hour, or to escalate to First Mate in its own status.

Both are answered through the crewmate's steering inbox and closed by the answer itself:

```sh
FM_HOME=<home> bin/fm-lead.sh steer --leader <leader-id> <crewmate-id> --resolve-key stuck "<one line: the cause you see and what to do next>"
```

The key on `--resolve-key` is the door's key (`story-size` or `stuck`); the record stays open until a `resolved` line carrying that exact key lands, and `fm-send` writes that line at answer time ([`bin/fm-send.sh`](../bin/fm-send.sh) header).
The ledger then records the door as answered at the watcher's next poll; a door that was rung, escalated or answered is never rung twice.

## At every checkpoint

Before a merge and after a crewmate's status wake, read one card per crewmate:

```sh
FM_HOME=<home> bin/fm-crew-vitals.sh --leader <leader-id>
```

Four lines each, from the transcript, the status log, the worktree and the logbook ([`bin/fm-crew-vitals.sh`](../bin/fm-crew-vitals.sh) says what each field reads).
A head near the mark with no commit for an hour is a reason to read that crewmate's logbook, `data/<id>/logbook.md`, not a reason to say anything to it.
The card's `start` is the head at the crewmate's first request, what it carried before any work: the brief (measured at every spawn, warned above 6K tokens), the project's memory files and the launch; a firstmate-repo crewmate no longer carries First Mate's job description there ([`bin/fm-spawn.sh`](../bin/fm-spawn.sh) header, "The fresh head").
`bin/fm-lead.sh crew --leader <leader-id>` lists the crewmates with a liveness read of each endpoint; `bin/fm-crew-state.sh <id>` owns a crewmate's current state when the card's status word is not enough.

## On a trim wake

From a crewmate's second automatic trim on, one line lands in the leader's inbox: `trim event: <id> trimmed its context for the Nth time (head XK before it, line 140K) - steer or split the story; summary in data/<id>/trims/N.md` ([`bin/fm-trim-event.sh`](../bin/fm-trim-event.sh)).
Read that record against the story's acceptance criteria.

- If the summary is on the spec, steer nothing.
- If it is not, steer once: restate the goal in one line, pin what matters, name what to drop.
- If the crewmate's head is heavy with what it no longer needs, order a trim with a focus: `FM_HOME=<home> bin/fm-lead.sh trim --leader <leader-id> <crewmate-id> <what to keep>`.
  The order is written into the crewmate's trim ledger first, then `/compact <focus>` is typed into its pane; a crewmate that is mid-turn queues the typed order and trims at its next turn boundary (measured live on 2.1.259: typed 8 s into a 49 s turn, queued on screen, run 10 ms after the turn ended), so an order is never an interrupt.
  The trim that follows is recorded as the leader's (`- ordered by: leader <id>`) and rings nobody, but the crewmate itself is nudged: its own trim hook sends `trim done - continue: <focus>` into its inbox when the compaction ends.
  The command does not wait for any of that: it marks the order, types `/compact`, and returns, so nothing you run has to outlive a compaction for the crewmate to be told to carry on. The nudge is an append, so [the law of the head](#the-law-of-the-head) holds.
- If the story is two stories, write the split note for First Mate in your logbook and status.
- If the crewmate cannot be steered back, write the handover note from its logbook; First Mate relaunches, because a relaunch is irreversible and the leader never performs one.

After every trim the crewmate itself is handed its task card by its harness, read from disk: its brief's intent and definition of done, its logbook, the instructions waiting in its inbox, and its last status line ([`bin/fm-task-card.sh`](../bin/fm-task-card.sh)).
A steer that sits in the inbox at that moment is on the card.

## On a signal

Every five minutes the watcher reads each of your crewmates' cards and rings you, once per episode, when the transcript shows one of three shapes ([`bin/fm-crew-signals.sh`](../bin/fm-crew-signals.sh)):

- `signal: <id> stall: busy with nothing new for 17m (bound 15m); last call Bash \`...\`` - a tool call in flight, or a prompt the model has not answered, with nothing written for `FM_STUCK_CALL_SECS` (900): stuck in one call or wedged.
- `signal: <id> loop: loop 3x Bash \`bash tests/x.test.sh\` in the last 30 calls` - the same command three or more times in the last 30 calls, the same file read five or more times, or an A-B-A-B bounce.
- `signal: <id> drift?: 46K tokens since the last commit (82m) with no logbook change over that spend (bound 40K; logbook untouched)` - `FM_DRIFT_TOKENS` (40,000) spent since the last commit while the logbook did not change. A candidate, never a verdict: the question mark is deliberate.

The ring carries the crewmate's card and the steer command.
It is mechanical, from the transcript and nowhere else: nothing the crewmate writes, says or reports enters it, so a logbook that claims progress does not quiet a loop the transcript shows.
The card in the ring is the `--outside` one, without the logbook's next line - the card's one field in the crewmate's own words; run `bin/fm-crew-vitals.sh <id>` yourself when you want to read that line.
Read the pane and the logbook against the story's acceptance criteria, then steer once if the work is off, or do nothing if it is sound; a foreground test run that legitimately takes twenty minutes rings a stall once and needs no answer.
Each episode rings once (the ledger is `data/<id>/signals/index`); the same loop growing, or the same stall lengthening, stays silent, and a new shape rings again.
First Mate is not told about signals; a dead leader's crewmate signals go nowhere (one failed row), and First Mate learns of the dead leader through its own liveness reads.
The crewmate's own `stuck` door is a separate, human-shaped knock; the signals work whether or not it ever knocks.

## Steers

Steers are short; the crewmate reads each once, and the leader is measured on their size, never refused.
Steer with ordinary text:

```sh
FM_HOME=<home> bin/fm-lead.sh steer --leader <leader-id> <crewmate-id> "<the steer>"
```

`steer` sends the text through `fm-send` exactly as First Mate would (the durable inbox record plus the doorbell), refuses a crewmate outside your chain or one whose endpoint is dead (lifecycle is First Mate's), copies the first line into your own status as `note: steered <crewmate-id> (<chars> chars, <lines> lines): ...`, and measures the steer in `data/<leader-id>/steers/index` ([`bin/fm-lead.sh`](../bin/fm-lead.sh) header).
Over 1,200 characters it warns and sends anyway.
`FM_HOME` must be explicit, so a steer never resolves against another home.
Report your own progress to First Mate as status lines, as any crewmate does; a `note:` line reaches First Mate's next unread-status section without waking it, which is how First Mate sees every steer.

## The progress report

Every epic branch leader reports progress in one shape, stewarded on its branch as a rule (the captain's words, 2026-09-05):

- one line naming the goal the epic was given, in the captain's words;
- a progress bar in a code block, twenty cells, with the estimate as a percentage, weighted by what is left, never by story count;
- DONE - checkboxes ticked, one line each, written as what changed for a person, no commit ids;
- IN FLIGHT - unticked, one line each, with the next step and who holds it;
- QUEUED, FILED BY NAME - unticked, grouped, none started;
- one closing paragraph, "What the bar means": what the epic can do today and what the missing part buys.

Write it from your own logbook and the vitals, never from the crewmates' words.
The scaffold fills what it can read and leaves the rest to you:

```sh
FM_HOME=<home> bin/fm-progress.sh scaffold <leader-id> --estimate <pct> > data/<leader-id>/progress.md
```

It takes the goal from your brief's Captain's intent, the DONE lines from your logbook's `## Done` with commit ids struck out, the IN FLIGHT lines from your `## Next` (held by you) and from each crewmate's card (held by that crewmate, with its head, last commit and status word, the next step left for you), and placeholders for the queued names and the closing paragraph ([`bin/fm-progress.sh`](../bin/fm-progress.sh)).
The estimate is yours: what is done, weighted by what is left.
Keep the saved report at `data/<leader-id>/progress.md`; First Mate rolls every leader's bar into one fleet bar for the captain the same way, with `bin/fm-progress.sh fleet`.
It is a report, never a gate: nothing reads the bar to stop, score or rank anyone.

## The law of the head

Memory machinery appends, or acts at a trim; it never rewrites the head between trims.

The reason is the prompt cache.
A turn re-reads the crewmate's whole head, and the part of it that has not changed since the last turn is served from the cache at roughly a tenth of the price; only fresh input and output are the real burn.
Anything that changes the front of the head between turns - a memory file rewritten, a settings file touched, a hook that prints into the context on every prompt - forces one full-price re-read of everything, and a gap longer than the cache's life does the same.
So everything that measures or steers a crewmate from the outside obeys one law: it reads the transcript, the status log, the worktree and the logbook, and writes only under `data/` and `state/`; the two hooks that do speak into the head, the keep-set ([`bin/fm-compact-keep.sh`](../bin/fm-compact-keep.sh)) and the task card ([`bin/fm-task-card.sh`](../bin/fm-task-card.sh)), speak at a trim and nowhere else; a steer is a durable record in the crewmate's inbox plus one constant doorbell line, an append.
[`tests/fm-memory-append-law.test.sh`](../tests/fm-memory-append-law.test.sh) holds every piece of the machinery to it on a real spawn: the hooks the spawn installs (only the keep-set and the task card speak, both at a trim; every other hook runs and prints nothing; a hook on an event the suite has not classified fails it), and a run of the vitals, the signals check, the progress report, the leader's steer and trim order, the door relay and the trim-time scripts that leaves the worktrees, their memory files and harness settings, the user-level config, the project and the briefs byte-identical.
A story that needs to put something in front of the crewmate between trims is a story that busts the cache on every turn; say so in its plan and let the Hand weigh it.

## What the leader never does

- Never tells a crewmate about the machinery that measures it: no trim counts, no head sizes, no budgets in a brief or a steer.
- Never merges, relaunches, tears down or discards on its own word; First Mate holds the lifecycle, and the captain holds every merge.
- Never addresses the captain; everything goes through First Mate.
