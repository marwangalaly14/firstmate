# The branch leader's playbook

A branch leader is a crewmate that briefs, steers and supervises up to four crewmates of its own on one epic, and reports to First Mate the way any crewmate does.
This page is what a leader does at each of its moments and which script does the reading; the scripts' headers own their exact flags.
Two words hold everywhere: the leader measures its crewmates from the outside and never asks them to, and nothing it builds stops, throttles or warns a crewmate.

## What a leader is

- A leader is spawned as one: `bin/fm-spawn.sh ... --leads` records `leads=1` and leaves the harness's own trim line in place, because the epic's whole shape lives in the leader's head.
- Its crewmates are spawned under it: `bin/fm-spawn.sh ... --leader <leader-id>` records `leader=<leader-id>` in each crewmate's task record ([`bin/fm-lead-lib.sh`](../bin/fm-lead-lib.sh) owns the chain).
  The chain is one level deep: a led crewmate cannot lead, and a leader takes four crewmates at once; the spawn refuses a fifth, naming the four.
- Each crewmate's brief is scaffolded with the same leader: `bin/fm-brief.sh <id> <repo> --mode <mode> --leader <leader-id>` names the leader as the one who answers the crewmate's doors, and the spawn refuses a brief and a `--leader` that disagree ([`bin/fm-brief.sh`](../bin/fm-brief.sh) header).
- While a leader exists, First Mate's channel to a working crewmate carries lifecycle and the captain's words only, never the work.
- The leader keeps its own logbook, `data/<leader-id>/logbook.md`, for the epic's shape, its open steers and its pending splits; First Mate reads it when it watches the branch.

## The crewmate's two doors

A led crewmate's brief gives it exactly two reasons to surface before its story is done, both keyed status lines:

- `needs-decision: [key=story-size] {the two halves}` before it begins, when the story is two stories.
  Split, or hold the line with the reason and re-brief; the crewmate is the last check on the leader's cut.
- `blocked: [key=stuck] {what it tried, what it sees}` when it is looping or drifting.
  Answer in one steer, or escalate to First Mate.

Both are answered through the crewmate's steering inbox and closed by the answer itself:

```sh
FM_HOME=<home> bin/fm-send.sh <crewmate-id> --resolve-key stuck "<one line: the cause you see and what to do next>"
```

The key on `--resolve-key` is the door's key (`story-size` or `stuck`); the record stays open until a `resolved` line carrying that exact key lands, and `fm-send` writes that line at answer time ([`bin/fm-send.sh`](../bin/fm-send.sh) header).

## At every checkpoint

Before a merge and after a crewmate's status wake, read one card per crewmate:

```sh
FM_HOME=<home> bin/fm-crew-vitals.sh --leader <leader-id>
```

Four lines each, from the transcript, the status log, the worktree and the logbook ([`bin/fm-crew-vitals.sh`](../bin/fm-crew-vitals.sh) says what each field reads).
A head near the mark with no commit for an hour is a reason to read that crewmate's logbook, `data/<id>/logbook.md`, not a reason to say anything to it.
`bin/fm-lead.sh crew --leader <leader-id>` lists the crewmates with a liveness read of each endpoint; `bin/fm-crew-state.sh <id>` owns a crewmate's current state when the card's status word is not enough.

## On a trim wake

From a crewmate's second automatic trim on, one line lands in the leader's inbox: `trim event: <id> trimmed its context for the Nth time (head XK before it, line 140K) - steer or split the story; summary in data/<id>/trims/N.md` ([`bin/fm-trim-event.sh`](../bin/fm-trim-event.sh)).
Read that record against the story's acceptance criteria.

- If the summary is on the spec, steer nothing.
- If it is not, steer once: restate the goal in one line, pin what matters, name what to drop.
- If the story is two stories, write the split note for First Mate in your logbook and status.
- If the crewmate cannot be steered back, write the handover note from its logbook; First Mate relaunches, because a relaunch is irreversible and the leader never performs one.

After every trim the crewmate itself is handed its task card by its harness, read from disk: its brief's intent and definition of done, its logbook, the instructions waiting in its inbox, and its last status line ([`bin/fm-task-card.sh`](../bin/fm-task-card.sh)).
A steer that sits in the inbox at that moment is on the card.

## Steers

Steers are short; the crewmate reads each once, and the leader is measured on their size, never refused.
Steer with ordinary text:

```sh
FM_HOME=<home> bin/fm-send.sh <crewmate-id> "<the steer>"
```

`FM_HOME` must be explicit, so a steer never resolves against another home.
Report your own progress to First Mate as status lines, as any crewmate does; a `note:` line reaches First Mate's next unread-status section without waking it.

## What the leader never does

- Never tells a crewmate about the machinery that measures it: no trim counts, no head sizes, no budgets in a brief or a steer.
- Never merges, relaunches, tears down or discards on its own word; First Mate holds the lifecycle, and the captain holds every merge.
- Never addresses the captain; everything goes through First Mate.
