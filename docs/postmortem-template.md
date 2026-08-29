# Postmortem: &lt;what broke, as a sentence&gt;

**Task:** T-7.6 (#58) — this is the template. Copy it; do not edit it in place.

- **Date of the incident:**
- **Duration:** first bad request → last bad request, not first alert → all-clear
- **Detected by:** an alert, a person, or a customer. Which of the three is the finding
- **Author:**
- **Issue:**

---

## What a reader needs in thirty seconds

Two or three sentences. What was broken, for whom, for how long, and what made it stop. No
narrative yet.

## Impact

What could not be done, by whom, and how it appeared to them. Prefer "documents could not be
uploaded for 40 minutes; uploads returned a 502" to "the storage subsystem was degraded".

If nothing was affected, say so plainly. A near miss is worth a postmortem when the mechanism was
real, and pretending otherwise inflates the record.

## Timeline

Times in UTC, sourced from logs and alert timestamps rather than memory.

| Time | Event |
|---|---|
| | |

Include the gap between "it started" and "we knew". That gap is usually the most actionable number
in the document.

## What actually happened

The mechanism, not the story. A reader who does not know this system should be able to explain the
failure to somebody else after reading this section.

Say what was ruled out and how, especially where the obvious explanation was wrong. This repository
has twice recorded a lead that was investigated and turned out to be a coincidence, and both times
writing down the retraction saved the next person the same day.

## Why it was not caught sooner

The question is not "why did it break" — that is the section above. It is why the thing that should
have said so did not.

Common answers here, all of which have happened in this project:

- there was no check
- there was a check and it reported success while governing nothing
- the alert existed and went to a receiver nobody reads
- it fired correctly and the runbook link pointed at a section that had been renamed

## What is being changed

One table. Every row is a card or a commit, not an intention.

| Change | Why it prevents a repeat | Issue |
|---|---|---|
| | | |

**A change that cannot be checked is not a change.** "Be more careful when editing X" is a note to
self; "a check refuses the edit" is a fix. Where the honest answer is that no automated check is
possible, write that down as an accepted risk with a trigger rather than as an action item that
will quietly not happen.

## What went right

Not a formality. If a check caught this earlier than it would have been caught a month ago, that is
evidence the last postmortem's actions worked, and it is the only feedback that mechanism ever gets.

## Blameless, and what that actually means here

Nobody is named as a cause. A person doing a reasonable thing and getting an outage is a system
that permits an outage from a reasonable thing, and the system is what this document is about.

Being blameless is not being vague. "The apply was run against the wrong environment" is a
mechanism and belongs here; "someone was careless" is not a mechanism and does not.
