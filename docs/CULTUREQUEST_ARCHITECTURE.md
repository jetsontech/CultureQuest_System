# CultureQuest Platform Architecture

## Platform Layers
- Web app: Flask + Jinja templates
- Playback: HLS.js in browser, local HLS proxy in Flask
- Metadata: SQLite for channels, assets, schedules, users, subscriptions, favorites, history, recordings
- Ingestion: M3U import scripts + mirror assets + schedule generation
- Admin ops: channels, assets, schedules, plans, recordings

## Company-grade roadmap
### Core experience
- Live TV rails
- Favorites
- Watch history
- Category pages
- Mobile-safe UI
- Remote/TV style controls

### Viewer platform
- Sign up / auth
- Free + premium plans
- Continue watching
- Favorites + watch history APIs

### Content ops
- Assets
- Scheduling
- EPG generation/import
- Logo mirroring
- Channel health checks
- Recordings scheduler

### Infra progression
- SQLite now
- PostgreSQL later
- Redis queue later
- FFmpeg workers later
- CDN later
- Payment provider later
- Object storage later

## One-click foundation delivered
This foundation installs the schema, templates, and routes required to evolve CultureQuest from a prototype into a structured streaming company system.
