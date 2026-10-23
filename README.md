# RigReady — fixture & console maintenance log

Scan a QR code → see the item's full history → log a fault, repair or service with photos.
Built for lighting fixtures and consoles, works on phone and laptop, with team log-ins.

## What it does
- **Scan** your existing QR codes (phone camera, or a USB/Bluetooth scanner gun on a laptop). Codes match the item's asset tag, then its serial. Unknown code → add the item on the spot.
- **Per-item history**: every fault, repair, service, inspection and note, with who did it, parts used, hours and photos.
- **Alerts**: dashboard flags anything faulty / in repair / out of service for more than 60 days (change in `config.js`).
- **Service schedules**: by model ("every MegaPointe: clean fans every 180 days") or by single item, by days and/or run hours. Overdue and due-soon lists, one-tap "Done".
- **Manuals**: upload PDFs or add links per make/model — they show on every matching item.
- **Reports**: CSV exports (inventory, log by date range, faults, service due) and printable PDFs (item history, fault report).
- **Team**: everyone has their own log-in. Admins approve new people and are the only ones who can delete things.

## Try it now (demo mode)
Open `index.html` in a browser. With `config.js` left blank it runs on sample data saved in that browser only.

## Go live (about 15 minutes, free)

### 1. Create the database
1. Sign up at **supabase.com** → **New project** (pick the Sydney region).
2. Open **SQL Editor** → **New query**, paste all of `schema.sql`, click **Run**.
3. **Authentication → Sign In / Providers → Email**: leave Email enabled. Turn **Confirm email** OFF — new people still can't see anything until an admin approves them, and Supabase's built-in email only sends a few emails per hour.
4. **Project Settings → API**: copy the **Project URL** and the **anon / publishable** key into `config.js`.

### 2. Put it online (GitHub Pages)
1. Create a new GitHub repo (e.g. `benchlog`) and upload all the files in this folder.
2. Repo **Settings → Pages** → Source: *Deploy from a branch* → `main` / root → Save.
3. In Supabase, **Authentication → URL Configuration** → set **Site URL** to your Pages address (e.g. `https://yourname.github.io/benchlog/`) so password-reset links come back to the app.

The camera only works over **https**, which GitHub Pages gives you.

### 3. Set up the team
1. Open the site and **Create account** — the **first account becomes Admin**.
2. Send the link to your techs. They create an account and appear on the **Team** page as *Pending*.
3. Set them to **Technician** (or Admin).

On phones: open the site → Share → **Add to Home Screen** so it opens like an app.

## Tips
- **Scanner guns** type the code and press Enter — just click into the Scan box and scan.
- **Deep links**: `…/#/tag/LX-0101` opens that item directly. If you ever reprint labels, encoding that URL lets any phone camera jump straight to the item.
- **Hours** are whatever you track (lamp hours or run hours). Hours-based schedules compare each item's latest hours reading with the reading at its last service.
- Status changes go through log entries, so there's always a record of who changed what and when.

## Files
| File | What it is |
|---|---|
| `index.html` | The whole app |
| `config.js` | Your Supabase keys and settings (alert days, app name) |
| `schema.sql` | Database tables, access rules and file storage |
| `manifest.webmanifest`, `icon.svg` | Home-screen app icon |
