# PacketRat Full Intelligence Report — Engineering Audit
**Audit scope:** MailHawk (now PacketRat) `main` report pipeline as inspected October 22, 2026, and the proposed fixes in `feat/report-actionability-and-cleanup`.

**Evidence limitation:** An actual raw AI model report from the user's workstation was **not** supplied. This audit examines the full implementation path and uses synthetic reproductions of typical formatting problems. It does not assert that every reported artifact is reproducible from the user's exact provider response.

## Executive finding

MailHawk (now PacketRat) historically treated two separate AI model outputs — a structured `must_reply` object and a long human-readable Markdown narrative — as loosely coupled. Most report prose was not associated with validated Outlook records. Character conversion was inconsistent, and a fallback parser could infer must-reply items from table rows outside the appropriate section. This combination made the interface hard to trust or act on.

The new design uses **three distinct layers**: the provider's raw textual suggestion, a local evidence-and-rule reconciliation step, and a safe interactive presentation. No generated text is permitted to provide its own actionable Outlook EntryID.

## Section-by-section assessment

| Report area | Prior weakness | Improvement / requirement |
|---|---|---|
| Categories | High-level labels without source provenance | Each reported email reference must use an index verified in the original mailbox scan; source list can be inspected independently |
| Groups | Tables lacked context-sensitive operations | Linked table rows and `[Email #N]` references open the verified message, with draft/track operations on source cards |
| Must Reply | Narrative and actual action queue could disagree | Compare model recommendations to deterministic rules and saved user overrides; surface disagreements visibly |
| Already Appears Replied / No Action Needed | Generic fallback table parser could convert benign rows into action items | Restrict fallback extraction strictly to the Must Reply section; never turn other numbered rows into tasks |
| Skipped / Caution | Important exclusion reasons and sources were easy to miss | Keep sensitive/skipped messages out of actionable source lists; show quality warnings without exposing skipped content |
| Quick Summary | Read-only paragraph made it hard to produce useful outputs | Generate an action plan, executive brief, risk review, or explanation from the validated report/selected section |
| Applied triage policy | Count of rule matches lacked explanation of effective outcomes | Effective report source status indicates manual priority and rule exclusions; disagreements are flagged |

## Detailed issues and findings

1. **Encoding artifacts / mojibake.** The original browser renderer only stripped leading quote chevrons and escaped HTML, while the PowerShell engine kept the text returned by the AI model. Examples of UTF-8 bytes misread as Windows-1252 can produce `â€™`, `â€“`, `Ã©`, `Â `. Remediation: conservative, exact Unicode repairs on the server plus browser normalization for legacy reports. No blanket deletion of non-ASCII content. Unrepairable replacement characters remain visible as quality warnings.
2. **Escaped text and Markdown noise.** Literal `\n`, HTML entities, blockquote markers `>`, Markdown code fences, broken tables, and plain-text numbered headings were inconsistently rendered. Remediation: a reusable browser report presentation module with safe HTML escaping, predictable sections and tables, and targeted escape cleanup. Source report content remains separately copyable.
3. **Action provenance.** Outlook links were only reliably available from the action queue, not the narrative report. Remediation: `report_items` indexed references are resolved against the original mailbox snapshot. Invalid, sensitive, dismissed, or invented indices are rejected. Legacy reports can still show the verified inbox source list without guessing identities from arbitrary prose.
4. **Dangerous table fallback.** Legacy `ConvertFrom-PacketRatMustReplyFallback` scanned general tables and recognized bare row indices. This could inadvertently elevate rows from categories or no-action sections. Remediation: limit fallback text to the Must Reply section only. The user's explicit manual decisions and deterministic policy remain authoritative.
5. **Model output truncation risk.** The model is asked to produce JSON plus six narrative sections in one response, currently limited to 8,192 output tokens even for a scan of up to 150 emails. The model may omit sections or return truncated JSON. Remediation: detect unfinished structured blocks and warn; do not display partial JSON as a report or infer tasks from it. **Longer-term recommendation:** schema-first classification in batches, then generate the narrative from reconciled records.
6. **Report/action queue contradictions.** Local rules are applied *after* the AI model narrative is written, so `Must Reply` prose can contradict a rule that excludes a message, or a manual priority change. Remediation: report source cards show effective rule suppression, priority override, and actual tracked status; quality warns about disagreements. **Longer-term recommendation:** rebuild the visible report from reconciled structured records rather than accepting conflicting model prose.
7. **Unclear confidence and evidence.** The report lacks a systematic separation of model evidence, uncertainty, due-date extraction, and assumption. Recommendation: introduce typed fields for `source_index`, `reason`, `requested_action`, `deadline`, `evidence_span`, `confidence`, `classification_source`, and `overridden_by_user`; show confidence cautiously rather than inventing accuracy scores.
8. **Weak interactivity.** Static category headings and tables could not become work products. Remediation: actions for Open Outlook, Draft Reply, Track Action, and Generate from Report/Section. AI-generated follow-ups do not automatically write to task state or send email; human review is required.
9. **Privacy and traceability.** A complete real report can contain official mail information. Raw AI response logs are already opt-in; the new feature does not upload reports to GitHub, log tokens, or persist derivative briefings to browser storage. Only approved configured AI endpoints should receive these report follow-ups.
10. **Session lifetime and audit history.** The full report exists only in the running service's `LastResult`; a browser restart or server restart cannot reliably compare runs. Recommendation: add an approved local encrypted report history and diff view with explicit retention controls. No such persistent history is claimed here.
11. **Provider differences.** Outlook COM can open verified message EntryIDs; Graph IDs cannot be passed to Outlook COM. The interface now reports this limitation rather than assuming that all sources can open in the same client. Approved Graph deep-link support needs separate validation. Update: Graph messages are now matched to classic Outlook by Internet message id (`Find-PacketRatOutlookEntryIdByInternetMessageId`); this works only when the same message is in the local Outlook profile, and it has been tested against a fake object model only.
12. **Prompt-injection and fabricated citations.** Email previews and model report text must be treated as untrusted. Report references are verified by index against real scanned objects; HTML is escaped, generated links are never followed automatically, and follow-up report analysis is prompted to disregard instructions embedded in report text.

## Completed in the review branch

- New PowerShell report module: cleanup, verified source reconciliation, section parsing, report-quality metrics, scoped read-only generation
- AI model prompt extended with structured `report_items` alongside `must_reply`
- Native server routes for generated briefings and source-to-action tracking, subject to verified source keys
- Browser report presentation module: safe Markdown, known encoding repair, clickable references, verified source cards and report audit notes
- Updated report UI: section selector, generation mode selector, generated-output panel, per-section generation, source search and actions
- Regression tests: crafted encoding and HTML injection fixtures, invented-reference rejection, Must Reply section scoping, demo browser interactions, Windows PowerShell 5.1 parsing
- Rules reconciliation warnings and refusal to treat truncated structured JSON as reliable

## Recommended subsequent release

**High priority:** Replace the dual JSON-plus-freeform response with a schema-first AI classification pass and a deterministic report compiler. Separate factual observations from recommendations, with evidence references and conflict detection.

**Medium priority:** Provide confidence review tools, a rule effectiveness dashboard (manual changes and false-positive rates), thread-level grouping, explicit due-date recognition, and an approved cross-run report history.

**Later:** Graph-specific source opening, configurable approved export destinations, and cancellable background generation once the host architecture supports it.

## Workstation verification checklist

Use `Launch-PacketRat.bat demo` to test the interface and synthetic output. On an approved workstation, run live analysis and check: 1) actual AI model punctuation and characters; 2) at least one source reference opens its original message; 3) a report-sourced draft opens in Outlook without sending; 4) a previously untracked message can be added to the queue; 5) derived action plan uses the selected section; 6) user overrides are preserved; 7) no sensitive or regulated skipped message appears in actionable sources. Do not share unredacted official mail or tokens when reporting a bug.
