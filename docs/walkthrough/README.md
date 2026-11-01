# PacketRat walkthrough

Turn an inbox scan into an action queue and an interactive, source-checked report, without sending any email on your behalf.

> **Screenshots:** captured with demo data and scanned by the Chief of Staff (team directive 10).

## Before you start

- Windows PowerShell 5.1 (part of Windows). No administrator rights and no installer.
- Microsoft Edge or Google Chrome.
- Launch: Double-click `Launch-PacketRat.bat` (or `Launch-PacketRat.bat demo` for the offline demonstration with sample messages).
- Classic Outlook and an approved AI endpoint for real use. The demo needs neither.

## Steps

### 1. First launch

PacketRat opens on **Overview** with the latest inbox metrics. In the interactive demo, a banner says only sample inbox data is used, with no connection to Outlook or AI.

![PacketRat Overview in interactive demo mode: 3 open actions, 2 high priority, 1 completed and 0 noise filtered.](../assets/walkthrough/01-first-launch.png)

### 2. Work the action queue

**Action queue** lists every follow-up by urgency and status, with buttons to open it in Outlook, draft a reply, change its priority, or mark it done, in progress or dismissed. The demo inbox also has an *Office Updates* sample message.

![PacketRat Action queue with four demo follow-ups sorted by priority: two high, one medium and one low that is already done.](../assets/walkthrough/02-action-queue.png)

### 3. Draft a reply

Select **Draft** on an item. Add optional guidance, select **Generate draft**, then edit the text before you copy it or open it in Outlook. PacketRat never sends it for you.

![PacketRat Draft a response dialog for the demo access request, with a short unsent draft and Copy text and Open in Outlook buttons.](../assets/walkthrough/03-draft-response.png)

### 4. Read the briefing

**AI intelligence** shows the report with verified links back to the source messages.

![PacketRat AI intelligence briefing for the demo inbox: 5 verified messages, 6 report sections, and Categories linking back to the source emails.](../assets/walkthrough/04-ai-intelligence.png)

### 5. Generate a follow-up

Select a section and generate an **Action plan**, **Leadership briefing**, **Risk review** or **Explanation**.

![PacketRat AI intelligence report with a generated prioritized action plan for the selected section, marked as simulated analysis.](../assets/walkthrough/05-report-followup.png)

### 6. Manage dismissals

**Dismissal memory** keeps false positives out. Restore any of them at any time. A toast confirms each change, here *Action updated*.

![PacketRat Dismissal memory page with the Action updated toast, the dismissed demo message Meeting agenda feedback, and its Restore button.](../assets/walkthrough/06-dismissal-memory.png)

### 7. Check the configuration

**Configuration** shows the session settings. Credentials stay on the PowerShell side.

![PacketRat Engine configuration page for the demo session: Desktop Outlook, 40 emails over 14 days, with no credentials shown.](../assets/walkthrough/07-configuration.png)

## About these images

Images live in [`docs/assets/walkthrough/`](../assets/walkthrough/), named `NN-<screen>.png` after the step they belong to. They are 1440x900 at 100% scale in the Night watch (dark) theme, and show demo data only. `node tools/capture-screenshots.mjs` retakes them, with the README pair in `docs/screenshots/`, from the offline demo.
