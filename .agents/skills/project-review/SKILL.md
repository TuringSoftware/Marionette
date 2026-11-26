---
name: project-review
description: Review a finished Marionette change before it is submitted. Runs the harness's built-in code review at high effort, applies its fixes, checks the change against the project's coding guide and contribution rules, and fixes the commit attribution. Required by CONTRIBUTING.md for every AI-assisted pull request; use it when asked to review, prepare or submit a branch or pull request.
---

# Project review

The gate every AI-assisted change passes before a pull request ([CONTRIBUTING.md](../../../CONTRIBUTING.md)).
Work through the steps in order on the final state of the branch. Do not push or open the pull
request yourself unless the submitter asks.

## 1. Find the change

The change is everything the pull request would contain: the commits on this branch that are not on
the main branch, plus anything uncommitted. If that is empty, say so and stop.

## 2. Run the built-in code review

Run your harness's own code review command or tool on that change, at effort **high** or above.
Where the tool has no effort levels, use its most thorough setting. Do not replace it with a review
you improvise: if the harness has no built-in review, tell the submitter that this step cannot be
done here and stop.

Apply every fix the review recommends. A recommendation that turns out to be wrong (it breaks a
test, or contradicts the coding guide) is not dropped silently: leave the code as it was and report
the recommendation and your reason in step 7.

## 3. Check the coding guide

Read [Docs/coding-guide.md](../../../Docs/coding-guide.md) in full, then read every changed file
against it and fix what does not conform. The built-in review does not know these rules, so do not
assume it covered them. The comment rules are the ones most often broken by generated code: apply the
guide's test to every comment the change adds.

## 4. Check the contribution rules

Check each numbered requirement under "Submitting a pull request" in CONTRIBUTING.md. For the rule on
identifying details, search the whole change, binary fixtures included, not only the lines you
remember writing.

## 5. Test again

Steps 2 to 4 changed code. Run what CONTRIBUTING.md requires again, as
[Docs/testing.md](../../../Docs/testing.md) describes, and fix what fails. Run the UI tests only when
the change touches the UI: a screen, control, gesture or user-visible text, or code under `App/`.
A change to scripts, documentation, skills or CI skips them; say so in the report. Report a test
you could not run; never report it as passed.

## 6. Fix the attribution

Make every commit of the change follow the "Attribution" section of CONTRIBUTING.md, and the pull
request description too if one is drafted. Use one tag for each model that worked on the change,
including the one running this review. Rewrite only commits that belong to this change and have not
been merged.

## 7. Report

Tell the submitter, briefly:

- what the built-in review found and what was fixed;
- any recommendation not applied, with the reason;
- what steps 3 and 4 changed;
- each test run and its result, and anything not run;
- the attribution lines now on the commits.
