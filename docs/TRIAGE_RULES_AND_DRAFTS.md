# PacketRat: explainable triage and drafting

## Why the rule layer exists

A language model can misidentify direct questions, mandatory work, and automated FYI notifications. PacketRat treats AI classifications as suggestions and applies a small, deterministic, editable rule layer. User decisions have precedence. Rules do **not** automatically send, delete, or archive mail.

## Default rules (ordered)

| Order | Condition | Default effect |
|---|---|---|
| 1 | Recognized security alerts, mandatory action language, action required | High |
| 2 | Verified direct recipient + sender in your organization domain (`PACKETRAT_ORG_DOMAIN`) + request/question language | High |
| 3 | Verified direct recipient + request/question language | Medium |
| 4 | Already replied without a new request | Exclude from suggested queue |
| 5 | Routine automated digest/newsletter with no clear action request | Exclude from suggested queue |

A sender merely using **your organization domain** does *not* imply action is required. This is intentional: many official addresses distribute automated notices and FYIs. If you want every sender from your organization domain reviewed, use a custom **Any sender from your organization domain** rule with an appropriate outcome.

**Organization domain:** set `PACKETRAT_ORG_DOMAIN` in `Config/packetrat.env` to your mail domain (or several, comma-separated; a domain suffix also works). Rules 2 and **Any sender from your organization domain** never match while it is unset. Rules saved under the former rule match names are read and saved under the new names.

**Direct recipient detection:** In Outlook COM mode, the tool checks the To field against the current Outlook user identity (SMTP address or display name). You can specify `PACKETRAT_USER_EMAIL` if your organization uses an alias the resolver cannot identify. In Graph mode, the tool uses the authorized signed-in account or that explicitly configured email and checks `toRecipients`. If PacketRat cannot verify direct delivery, `IsDirect` is false; it should not guess and promote a message. CC-only and group traffic do not automatically count as direct.

## Rules in the GUI

Open **Configuration → Intelligence rules** to review, enable/disable, reorder, or change rule outcomes. Custom literal patterns support sender domain, sender text, subject, and preview text. The engine does not execute model-authored code or arbitrary regular expressions. Rule order matters; first matching rule wins.

**High / Medium / Low** assigns urgency. **Exclude suggestion** suppresses the matched message from the action queue without deleting the email or pretending the user dismissed it.

Open **Dismissal memory → Excluded by intelligence rules** to review rule-filtered items. **Keep in queue** makes the user's priority choice explicit so future analysis won't re-hide it. Dismissals are separately preserved, and changing a rule doesn't erase a prior user dismissal.

When you manually adjust High/Medium/Low on an action, PacketRat saves a `PriorityOverride`. Subsequent rescans refresh metadata but do not overwrite your priority. **Reset priority** restores the most recently suggested AI/rule priority.

All rules and status changes are stored locally under the ignored `Logs/` application data. They are not committed to Git.

## Report rendering

The original AI report stays plain text for clipboard export. The browser converts its Markdown sections, numbered headings, bullet points and tables into readable, escaped HTML. Leading blockquote `>` symbols are treated as model formatting noise, not quoted testimony. Source text is not executed as HTML or JavaScript.

## Draft alternatives

PacketRat requests **20,000 output tokens** from the configured model as a budget ceiling; the target email itself should normally be much shorter. The actual provider/model may have a smaller allowed ceiling, in which case its API error must be investigated rather than silently misrepresenting provider capabilities.

The default prompt requests two distinct alternatives in JSON. If the provider returns labeled Markdown, the parser splits Option A/B, Response A/B, or Draft 1/2 into separately editable response tabs. The selected tab is what **Copy** and **Open in Outlook** use. Outlook opens a reply composer for human review; PacketRat never calls Send.

## Limits

- Real-world Outlook COM, Graph, Lazarette and approved AI connectivity still need testing on the target secured workstation.
- Rule matching is heuristic, not authoritative; a false positive or negative can still happen. Users should review time-sensitive or security-sensitive messages.
- No separate encrypted rules database, continuous scheduler, or live agent streaming has been implemented in this release.
