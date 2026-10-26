# PacketRat walkthrough

Turn an inbox scan into an action queue and an interactive, source-checked report, without sending any email on your behalf.

> **Status: skeleton.** The screenshots below are placeholders. Zombie Admin captures them with demo data, and the Chief of Staff scans them for sensitive content before they are added (team directive 10). Until then the image links do not resolve.

## Before you start

- Windows PowerShell 5.1 (part of Windows). No administrator rights and no installer.
- Microsoft Edge or Google Chrome.
- Launch: Double-click `Launch-PacketRat.bat` (or `Launch-PacketRat.bat demo` for the offline demonstration with sample messages).
- Classic Outlook and an approved AI endpoint for real use. The demo needs neither.

## Steps

### 1. First launch

PacketRat opens on **Overview** with the latest inbox metrics.

![PacketRat Overview in demo mode, with inbox summary metrics for four sample messages.](../assets/walkthrough/01-first-launch.png)

### 2. Work the action queue

**Action queue** lists every follow-up by urgency and status.

![PacketRat Action queue with four demo follow-ups sorted by urgency.](../assets/walkthrough/02-action-queue.png)

### 3. Draft a reply

Open an item and draft a response. PacketRat never sends it for you.

![PacketRat Draft a response dialog for the demo access request message, with an unsent draft.](../assets/walkthrough/03-draft-response.png)

### 4. Read the briefing

**AI intelligence** shows the report with verified links back to the source messages.

![PacketRat AI intelligence report for the demo inbox, with verified source references.](../assets/walkthrough/04-ai-intelligence.png)

### 5. Generate a follow-up

Select a section and generate an **Action plan**, **Leadership briefing**, **Risk review** or **Explanation**.

![PacketRat AI intelligence page with a generated action plan for one report section.](../assets/walkthrough/05-report-followup.png)

### 6. Manage dismissals

**Dismissal memory** keeps false positives out. Restore any of them at any time.

![PacketRat Dismissal memory page with one dismissed demo message and its Restore button.](../assets/walkthrough/06-dismissal-memory.png)

### 7. Check the configuration

**Configuration** shows the session settings. Credentials stay on the PowerShell side.

![PacketRat Engine configuration page for the demo session, with no credentials shown.](../assets/walkthrough/07-configuration.png)

## About these images

Images live in [`docs/assets/walkthrough/`](../assets/walkthrough/), named `NN-<screen>.png` after the step they belong to. They are 1440x900 at 100% scale in the Dark (PacketRat has one theme) theme, and show demo data only.
