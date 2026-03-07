# iPhone Push Alert Options

Options for sending alerts from the macOS MCP server to iPhone, ranked by practicality.

---

## 1. iMessage via AppleScript (most native, zero cost)

Existing AppleScript infrastructure can drive Messages.app to send to yourself:

```applescript
tell application "Messages"
    set targetService to 1st service whose service type = iMessage
    set targetBuddy to buddy "+1YOURNUMBER" of targetService
    send "Daily Briefing: 3 events today, 2 overdue reminders" to targetBuddy
end tell
```

**Pros:**
- No extra apps, no accounts, no API keys
- Shows as iMessage notification on iPhone instantly
- Can send rich text (links, etc.)
- Fits perfectly into existing `applescript.py` subprocess pattern

**Cons:**
- Messages.app AppleScript API has been flaky on recent macOS versions (Ventura+) — sometimes requires Messages.app to be open
- macOS TCC permission prompt for Automation access to Messages
- Can't send images/HTML (plain text only)
- Sending to yourself creates a "Note to Self" conversation

**Effort:** ~10 lines of Python wrapping an AppleScript call

---

## 2. Pushover ($5 one-time, most reliable)

iOS app with a dead-simple HTTP API. One POST request = push notification.

```python
import httpx

def push_alert(message: str, title: str = "Daily Briefing"):
    httpx.post("https://api.pushover.net/1/messages.json", data={
        "token": "YOUR_APP_TOKEN",
        "user": "YOUR_USER_KEY",
        "message": message,
        "title": title,
        "html": 1,  # supports basic HTML
        "priority": 0,  # -2 to 2 (2 = requires acknowledgment)
    })
```

**Pros:**
- Rock solid — purpose-built for this exact use case
- Supports HTML in notifications, priority levels, sounds, URLs
- Emergency priority (repeats until acknowledged)
- 10,000 messages/month free after $5 app purchase
- Works from anywhere (not tied to macOS)

**Cons:**
- $5 iOS app purchase
- Requires internet (your MCP tools don't)
- Another API token to manage

**Effort:** ~5 lines of Python. No AppleScript needed.

---

## 3. ntfy.sh (free, open source)

Free push notification service. iOS app available. No account needed for basic use.

```python
import httpx

def push_alert(message: str, title: str = "Daily Briefing"):
    httpx.post("https://ntfy.sh/your-secret-topic-name",
        content=message,
        headers={"Title": title, "Priority": "default"})
```

**Pros:**
- Completely free, no account needed
- Self-hostable if you want privacy
- iOS app, Android app, web UI
- Supports markdown, attachments, action buttons

**Cons:**
- Topics are public by default (use a long random topic name, or self-host)
- iOS app is less polished than Pushover
- Relies on external service (or self-hosting)

**Effort:** ~3 lines of Python

---

## 4. Create a Reminder with alert (iCloud push, zero cost)

Create a reminder with `due date = now` via AppleScript. iCloud syncs it to iPhone and the Reminders notification fires.

```applescript
tell application "Reminders"
    tell list "Inbox"
        make new reminder with properties {
            name: "Daily Briefing: 3 events, 2 overdue",
            body: "Check your email for full details",
            due date: current date,
            priority: 1
        }
    end tell
end tell
```

**Pros:**
- Zero cost, no extra apps
- Uses infrastructure you already have (Reminders.app)
- iPhone notification is native and reliable
- Reminder persists — you can see it later

**Cons:**
- Creates actual reminder clutter (need to complete/delete them)
- Notification is just the reminder title — limited formatting
- Slight iCloud sync delay (usually 1-30 seconds)
- You'd be adding a write operation (currently read-only server)

**Effort:** ~15 lines of AppleScript + Python wrapper

---

## 5. Calendar Event with alarm (iCloud push, zero cost)

Create a calendar event starting now with a 0-minute alarm. iCloud pushes the alert to iPhone.

```applescript
tell application "Calendar"
    tell calendar "Alerts"
        set newEvent to make new event with properties {
            summary: "Daily Briefing",
            start date: current date,
            end date: current date,
            description: "3 events today, 2 overdue reminders"
        }
        make new sound alarm at end of sound alarms of newEvent with properties {
            trigger interval: 0
        }
    end tell
end tell
```

**Pros/Cons:** Similar to reminders approach but creates calendar clutter instead.

---

## Recommendation

| Use Case | Best Option |
|---|---|
| Quick and native, already have the infra | **iMessage (#1)** |
| Most reliable, worth $5 | **Pushover (#2)** |
| Free + reliable + no Apple quirks | **ntfy.sh (#3)** |
| Want to stay 100% within Apple ecosystem | **Reminder (#4)** |

For the daily briefing agent specifically, a **two-tier** approach works well:

1. **Primary:** Email (already in `AIAgentAutomate_Specs.md`) — full HTML briefing
2. **Secondary:** Quick push notification (iMessage or Pushover) — 1-2 line summary like *"3 events today, 2 overdue reminders. Check email for details."*

The push notification acts as a nudge to check the full email.
