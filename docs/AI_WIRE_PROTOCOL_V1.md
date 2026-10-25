# PacketRat AI Wire Protocol v1

PacketRat accepts **versioned, delimited structured responses** instead of pasting arbitrary GenAI prose into the Outlook reply or HTML report.

## Why both delimiters and a schema?

The outer delimiter identifies the message kind and ensures the response is complete. The parser then validates its fields. The browser constructs its own presentation; the model never controls raw HTML or Outlook message metadata.

Source of truth: `Private/PacketRatProtocol.ps1`.

> **Envelope lifetime:** envelopes exist only between the model response and the parser. Nothing that is saved (the store, `PacketRatReport_*.md`, the opt-in raw AI log) is parsed again, so the markers can change between releases without a fallback.

`Private/PacketRatProtocol.ps1` uses ASCII-safe delimiter definitions for Windows PowerShell 5.1.

### Draft — exactly one reply

```text
<<<PACKETRAT_DRAFT_V1>>>
<<<SUBJECT>>>
RE: Access Request
<<<END_SUBJECT>>>
<<<BODY>>>
Thank you for the update.

I will review the request and follow up after confirming the remaining details.
<<<END_BODY>>>
<<<END_PACKETRAT_DRAFT_V1>>>
```

The model must return exactly **one** subject and **one** plain-text body. The subject is editable. **Outlook's original reply subject remains unchanged by default** to preserve threading. A user may explicitly select the opt-in override.

The model must **not** generate a signature, title, contact information, logos, or greetings presented as the user's identity. When PacketRat opens a classic Outlook reply, it calls `Display()` first so Outlook can insert the configured **Replies/Forwards signature for the sending account**. Then PacketRat inserts the reviewed body at the start of the existing HTML body, preserving its signature, inline images and quoted thread. For a plain-text reply, it prepends text while preserving what Outlook already placed in the body. PacketRat does not reconstruct a signature from sent email or manually copy signature files. **If Outlook has no configured reply signature, PacketRat does not invent one.**

A 20,000-output-token provider request ceiling is maintained for drafting; that is **not** a request to write 20,000 tokens of email. A provider's actual output-token limit may be smaller.

### Main report — one versioned JSON envelope

```text
<<<PACKETRAT_REPORT_V1>>>
{
  "version": "PACKETRAT_REPORT_V1",
  "must_reply": [{"index": 1, "urgency": "High", "why": "Source-supported request"}],
  "report_items": [{"index": 1, "section": "Must Reply", "reason": "Reply requested", "recommended_action": "Review and respond", "urgency": "High"}],
  "sections": [
    {"id": "categories", "title": "Categories", "summary": "Classification overview.", "items": []},
    {"id": "groups", "title": "Groups", "summary": "", "items": []},
    {"id": "must_reply", "title": "Must Reply", "summary": "", "items": [{"email_index": 1, "text": "Confirm the requested information."}]},
    {"id": "already_replied", "title": "Already Replied / No Action Needed", "summary": "", "items": []},
    {"id": "skipped", "title": "Skipped / Caution", "summary": "", "items": []},
    {"id": "quick_summary", "title": "Quick Summary", "summary": "Review pending actions.", "items": []}
  ]
}
<<<END_PACKETRAT_REPORT_V1>>>
```

All six section IDs are required **in that order**; empty sections use empty arrays. No markdown headings, tables, or arbitrary model-authored UI controls are accepted in section text. PacketRat validates JSON and reconciles model email indices against the original scan. It then constructs readable, escaped sections and click-through links for *verified* messages. Model-generated EntryIDs, HTML, and fabricated references are never trusted as action identifiers.

### On-demand follow-ups — insight envelope

```text
<<<PACKETRAT_INSIGHT_V1>>>
{"version":"PACKETRAT_INSIGHT_V1","title":"Action plan","summary":"Review the verified requests.","items":[{"email_index":1,"text":"Confirm the deadline from the original email."},{"email_index":0,"text":"Review uncertain classifications before acting."}]}
<<<END_PACKETRAT_INSIGHT_V1>>>
```

This covers briefings, explanations, risk reviews and follow-up plans generated from the full report or a selected report section. Email index **0** means general advice with no specific message citation. The compiled UI is read-only and never sends mail automatically.

## Parsing and error contract

- ASCII delimiters are exact, alone on their lines. CRLF is normalized to LF.
- No text, code fences, multiple envelopes, or prefaces outside the envelope.
- Strict JSON decoding for REPORT_V1 and INSIGHT_V1; explicit field sizes and supported section IDs.
- A malformed or truncated response **fails visibly**. There is no automatic fallback that dumps raw content into Outlook or promotes a row from another report section into the action queue.
- Markers cannot be duplicated inside a draft body. Plain-text email drafts must contain no embedded HTML.
- Outlook message identity comes from the locally verified scan, not from untrusted model prose.
- UTF-8 must be preserved end-to-end. The UI escapes HTML; repair of known legacy mojibake is kept in the dedicated report renderer. **Delimiters solve segmentation, not encoding**.
- Never store tokens or official mail data in GitHub. Raw AI logs are opt-in only.
- Future response contracts use a **new version identifier** rather than silently changing field semantics.

## Testing

Automated Windows PowerShell 5.1 tests check parsing success, duplicate/invalid/truncated rejection, verified source links, Outlook signature HTML preservation, and one draft per generation. Chromium tests check the single-draft GUI and structured report controls. Actual classic Outlook, configured reply signatures, provider output limits, account identity selection, and approved GenAI access still require workstation validation.

**Known limitation:** Classic Outlook and Microsoft Graph/new Outlook have different compose surfaces. The signature-preserving Outlook COM flow is for installed classic Outlook; we have not implemented Graph draft signature handling.
