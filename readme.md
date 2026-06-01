# AniRemind

Binary Cache:

- Cache: <https://cache.ysun.co>
- Key: `cache.ysun.co-1:WxPYwT5g3kt9XhUhHPpNLZKI9HIOsVVAuqSHpok8Qt4=`

Syncs [AniList](https://anilist.co) watchlist to Apple Reminders.

Use Nix to build and run directly:

```
nix run github:stepbrobd/aniremind -- -u <username> -r <list> [-l <language>] [--force]
```

| Flag             | Required | Description                                                          |
| ---------------- | -------- | -------------------------------------------------------------------- |
| `-u, --user`     | yes      | AniList username                                                     |
| `-r, --reminder` | yes      | Apple Reminders list name                                            |
| `-l, --language` | no       | Title language: `native`, `english`, or `romaji` (default: `native`) |
| `-f, --force`    | no       | Update reminders with changed airing schedules                       |

**Safe mode** (default): creates reminders for new shows, skips shows that
already have a reminder. Never modifies existing reminders.

**Force mode** (`--force`): additionally updates existing reminders whose airing
schedule has changed (due date, recurrence, alarm).

Idempotent on re-run in both modes.

Each reminder gets:

- **Title**: AniList title in the selected language (native/english/romaji)
- **Due date**: first upcoming episode air time, converted to local timezone
- **Alarm**: at the due date
- **Recurrence**: weekly until the last episode airs
- **URL**: AniList page for the show
- **Notes**: episode count and date range
