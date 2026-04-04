import EventKit
import Foundation

// MARK: - CLI

enum TitleLanguage: String {
  case native, english, romaji
}

struct Config {
  let username: String
  let reminderList: String
  let language: TitleLanguage
  let force: Bool
}

func usage() -> Never {
  fputs(
    """
    usage: AniRemind -u <username> -r <list> [--force]

      -u, --user       AniList username
      -r, --reminder   Apple Reminders list name
      -l, --language   Title language: native, english, romaji (default: native)
      -f, --force      Update reminders with changed airing schedules

    """, stderr)
  exit(1)
}

func parseArgs() -> Config {
  let args = CommandLine.arguments
  var username: String?
  var reminderList: String?
  var language: TitleLanguage = .native
  var force = false

  var i = 1
  while i < args.count {
    switch args[i] {
    case "-u", "--user":
      guard i + 1 < args.count else { usage() }
      username = args[i + 1]
      i += 2
    case "-r", "--reminder":
      guard i + 1 < args.count else { usage() }
      reminderList = args[i + 1]
      i += 2
    case "-l", "--language":
      guard i + 1 < args.count, let lang = TitleLanguage(rawValue: args[i + 1]) else {
        fputs("error: --language must be native, english, or romaji\n", stderr)
        usage()
      }
      language = lang
      i += 2
    case "-f", "--force":
      force = true
      i += 1
    default:
      usage()
    }
  }

  guard let u = username, let r = reminderList else { usage() }
  return Config(username: u, reminderList: r, language: language, force: force)
}

// MARK: - AniList GraphQL

struct AiringNode: Decodable {
  let episode: Int
  let airingAt: Int
}

struct AiringSchedule: Decodable {
  let nodes: [AiringNode]
}

struct Title: Decodable {
  let native: String?
  let english: String?
  let romaji: String?

  func resolved(_ language: TitleLanguage) -> String {
    switch language {
    case .native: return native ?? romaji ?? "(untitled)"
    case .english: return english ?? romaji ?? "(untitled)"
    case .romaji: return romaji ?? english ?? "(untitled)"
    }
  }
}

struct Media: Decodable {
  let title: Title
  let airingSchedule: AiringSchedule
  let siteUrl: String
}

struct Entry: Decodable {
  let media: Media
}

struct MediaList: Decodable {
  let entries: [Entry]
}

struct MediaListCollection: Decodable {
  let lists: [MediaList]
}

struct QueryData: Decodable {
  let MediaListCollection: MediaListCollection?
}

struct GraphQLResponse: Decodable {
  let data: QueryData
}

func fetchWatchlist(username: String) throws -> [Entry] {
  let query = """
    query($userName:String){
      MediaListCollection(userName:$userName,type:ANIME,status:CURRENT){
        lists{entries{media{
          title{native english romaji}
          airingSchedule(notYetAired:true,perPage:50){nodes{episode airingAt}}
          siteUrl
        }}}
      }
    }
    """
  let body: [String: Any] = [
    "query": query,
    "variables": ["userName": username],
  ]
  let json = try JSONSerialization.data(withJSONObject: body)

  var req = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
  req.httpMethod = "POST"
  req.setValue("application/json", forHTTPHeaderField: "Content-Type")
  req.setValue("AniRemind/1.0", forHTTPHeaderField: "User-Agent")
  req.httpBody = json

  let sem = DispatchSemaphore(value: 0)
  var result: Result<Data, Error>!

  let task = URLSession.shared.dataTask(with: req) { data, _, error in
    if let error = error {
      result = .failure(error)
    } else {
      result = .success(data ?? Data())
    }
    sem.signal()
  }
  task.resume()
  sem.wait()

  let data = try result.get()
  let resp = try JSONDecoder().decode(GraphQLResponse.self, from: data)
  guard let collection = resp.data.MediaListCollection else {
    fputs("error: user \"\(username)\" not found on anilist\n", stderr)
    exit(1)
  }
  return collection.lists.flatMap { $0.entries }
}

// MARK: - EventKit Helpers

func requestAccess(_ store: EKEventStore) -> Bool {
  let sem = DispatchSemaphore(value: 0)
  var granted = false

  if #available(macOS 14.0, *) {
    store.requestFullAccessToReminders { g, _ in
      granted = g
      sem.signal()
    }
  } else {
    store.requestAccess(to: .reminder) { g, _ in
      granted = g
      sem.signal()
    }
  }
  sem.wait()
  return granted
}

func fetchReminders(_ store: EKEventStore, in list: EKCalendar) -> [EKReminder] {
  let pred = store.predicateForReminders(in: [list])
  let sem = DispatchSemaphore(value: 0)
  var out: [EKReminder] = []
  store.fetchReminders(matching: pred) { r in
    out = r ?? []
    sem.signal()
  }
  sem.wait()
  return out
}

func findList(_ store: EKEventStore, name: String) -> EKCalendar {
  let calendars = store.calendars(for: .reminder)
  guard let cal = calendars.first(where: { $0.title == name }) else {
    let available = calendars.map { $0.title }.sorted().joined(separator: ", ")
    fputs("error: reminder list \"\(name)\" not found\n", stderr)
    fputs("available: \(available)\n", stderr)
    exit(1)
  }
  return cal
}

// MARK: - Reminder Operations

func configureReminder(
  _ reminder: EKReminder,
  media: Media,
  nodes: [AiringNode],
  fmt: DateFormatter
) {
  let startAt = Date(timeIntervalSince1970: TimeInterval(nodes.first!.airingAt))
  let endAt = Date(timeIntervalSince1970: TimeInterval(nodes.last!.airingAt))

  reminder.dueDateComponents = Calendar.current.dateComponents(
    [.year, .month, .day, .hour, .minute, .second, .timeZone],
    from: startAt
  )

  reminder.alarms?.forEach { reminder.removeAlarm($0) }
  reminder.addAlarm(EKAlarm(absoluteDate: startAt))

  reminder.recurrenceRules = [
    EKRecurrenceRule(
      recurrenceWith: .weekly,
      interval: 1,
      end: EKRecurrenceEnd(end: endAt)
    )
  ]

  reminder.url = URL(string: media.siteUrl)
  reminder.notes =
    "\(nodes.count) episodes, \(fmt.string(from: startAt)) - \(fmt.string(from: endAt))"
}

func dueDate(of reminder: EKReminder) -> Date? {
  reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
}

// MARK: - Sync

func run() throws {
  let config = parseArgs()

  let store = EKEventStore()
  guard requestAccess(store) else {
    fputs("error: reminders access denied\n", stderr)
    exit(1)
  }

  let list = findList(store, name: config.reminderList)
  print("list: \(list.title)")
  print(
    "timezone: \(TimeZone.current.identifier) "
      + "(UTC\(TimeZone.current.secondsFromGMT() >= 0 ? "+" : "")"
      + "\(TimeZone.current.secondsFromGMT() / 3600))\n")

  let existing = fetchReminders(store, in: list)
  let existingByTitle = Dictionary(
    existing.map { ($0.title ?? "", $0) },
    uniquingKeysWith: { first, _ in first }
  )
  var existingByURL: [String: [EKReminder]] = [:]
  for reminder in existing {
    if let url = reminder.url?.absoluteString {
      existingByURL[url, default: []].append(reminder)
    }
  }
  print("found \(existing.count) existing reminder(s)")

  let entries = try fetchWatchlist(username: config.username)
  print("fetched \(entries.count) show(s) from anilist\n")

  let fmt = DateFormatter()
  fmt.dateFormat = "yyyy-MM-dd HH:mm"
  fmt.timeZone = TimeZone.current

  var created = 0
  var updated = 0
  var skipped = 0
  var replaced = 0

  for entry in entries {
    let media = entry.media
    let title = media.title.resolved(config.language)
    let nodes = media.airingSchedule.nodes

    guard !nodes.isEmpty else {
      print("  skip: \(title) (no upcoming episodes)")
      skipped += 1
      continue
    }

    if let existing = existingByTitle[title] {
      if config.force {
        let newStart = Date(timeIntervalSince1970: TimeInterval(nodes.first!.airingAt))
        if dueDate(of: existing) != newStart {
          configureReminder(existing, media: media, nodes: nodes, fmt: fmt)
          try store.save(existing, commit: false)
          print("  update: \(title)")
          updated += 1
        } else {
          print("  skip: \(title) (up to date)")
          skipped += 1
        }
        // Clean up reminders for the same show in a different language
        if let dupes = existingByURL[media.siteUrl] {
          for dupe in dupes where dupe.title != title {
            try store.remove(dupe, commit: false)
            print("  delete: \(dupe.title ?? "(untitled)") (duplicate)")
            replaced += 1
          }
        }
      } else {
        print("  skip: \(title) (already exists)")
        skipped += 1
      }
      continue
    }

    var isReplace = false
    if config.force, let dupes = existingByURL[media.siteUrl], !dupes.isEmpty {
      for dupe in dupes {
        try store.remove(dupe, commit: false)
      }
      isReplace = true
      replaced += 1
    }

    let reminder = EKReminder(eventStore: store)
    reminder.calendar = list
    reminder.title = title
    configureReminder(reminder, media: media, nodes: nodes, fmt: fmt)
    try store.save(reminder, commit: false)
    if isReplace {
      print("  replace: \(title)")
    } else {
      print("  add: \(title)")
    }
    created += 1
  }

  try store.commit()
  print("\ndone: \(created) created, \(updated) updated, \(replaced) replaced, \(skipped) skipped")
}

do {
  try run()
} catch {
  fputs("error: \(error)\n", stderr)
  exit(1)
}
