import EventKit
import Foundation

// MARK: - Failure

struct Fail: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

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
    usage: aniremind -u <username> -r <list> [-l <language>] [--force]

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

struct GraphQLError: Decodable {
  let message: String
}

struct GraphQLResponse: Decodable {
  let data: QueryData?
  let errors: [GraphQLError]?
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
  var req = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
  req.httpMethod = "POST"
  req.setValue("application/json", forHTTPHeaderField: "Content-Type")
  req.setValue("AniRemind/1.0", forHTTPHeaderField: "User-Agent")
  req.httpBody = try JSONSerialization.data(withJSONObject: body)

  let sem = DispatchSemaphore(value: 0)
  var response: (data: Data?, error: Error?) = (nil, nil)
  URLSession.shared.dataTask(with: req) { data, _, error in
    response = (data, error)
    sem.signal()
  }.resume()
  sem.wait()

  if let error = response.error {
    throw Fail("anilist request failed: \(error.localizedDescription)")
  }
  guard let data = response.data else {
    throw Fail("empty response from anilist")
  }
  let envelope = try JSONDecoder().decode(GraphQLResponse.self, from: data)
  if let messages = envelope.errors?.map(\.message), !messages.isEmpty {
    throw Fail("anilist: \(messages.joined(separator: "; "))")
  }
  guard let collection = envelope.data?.MediaListCollection else {
    throw Fail("anilist returned no watchlist for user \"\(username)\"")
  }
  return collection.lists.flatMap(\.entries)
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

func fetchReminders(_ store: EKEventStore, in list: EKCalendar) throws -> [EKReminder] {
  let sem = DispatchSemaphore(value: 0)
  var result: [EKReminder]?
  store.fetchReminders(matching: store.predicateForReminders(in: [list])) { reminders in
    result = reminders
    sem.signal()
  }
  sem.wait()
  guard let reminders = result else {
    throw Fail("could not read reminders from \"\(list.title)\"")
  }
  return reminders
}

func findList(_ store: EKEventStore, name: String) throws -> EKCalendar {
  let calendars = store.calendars(for: .reminder)
  guard let list = calendars.first(where: { $0.title == name }) else {
    let available = calendars.map(\.title).sorted().joined(separator: ", ")
    throw Fail("reminder list \"\(name)\" not found\navailable: \(available)")
  }
  return list
}

// MARK: - Reminder Operations

struct Airing {
  let episodes: Int
  let start: Date
  let end: Date

  init?(_ nodes: [AiringNode]) {
    guard let first = nodes.first, let last = nodes.last else { return nil }
    episodes = nodes.count
    start = Date(timeIntervalSince1970: TimeInterval(first.airingAt))
    end = Date(timeIntervalSince1970: TimeInterval(last.airingAt))
  }
}

func configure(_ reminder: EKReminder, media: Media, airing: Airing, fmt: DateFormatter) {
  var cal = Calendar.current
  cal.timeZone = .gmt
  reminder.timeZone = .gmt
  reminder.dueDateComponents = cal.dateComponents(
    [.year, .month, .day, .hour, .minute, .second, .timeZone],
    from: airing.start
  )

  reminder.alarms?.forEach { reminder.removeAlarm($0) }
  reminder.addAlarm(EKAlarm(absoluteDate: airing.start))

  reminder.recurrenceRules = [
    EKRecurrenceRule(
      recurrenceWith: .weekly,
      interval: 1,
      end: EKRecurrenceEnd(end: airing.end)
    )
  ]

  reminder.url = URL(string: media.siteUrl)
  reminder.notes =
    "\(airing.episodes) episodes, \(fmt.string(from: airing.start)) - \(fmt.string(from: airing.end))"
}

func removeDuplicates(
  _ store: EKEventStore, of media: Media, keeping title: String, in index: [String: [EKReminder]]
) throws -> Int {
  var removed = 0
  for dupe in index[media.siteUrl, default: []] where dupe.title != title {
    try store.remove(dupe, commit: false)
    print("  delete: \(dupe.title ?? "(untitled)") (duplicate)")
    removed += 1
  }
  return removed
}

func dueDate(of reminder: EKReminder) -> Date? {
  reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
}

func needsUpdate(_ reminder: EKReminder, airing: Airing) -> Bool {
  dueDate(of: reminder) != airing.start
    || reminder.dueDateComponents?.timeZone?.identifier != TimeZone.gmt.identifier
}

// MARK: - Sync

func utcOffset(_ tz: TimeZone = .current) -> String {
  let seconds = tz.secondsFromGMT()
  let sign = seconds < 0 ? "-" : "+"
  let hours = abs(seconds) / 3600
  let minutes = abs(seconds) % 3600 / 60
  if minutes == 0 { return "UTC\(sign)\(hours)" }
  return String(format: "UTC%@%d:%02d", sign, hours, minutes)
}

func run() throws {
  let config = parseArgs()

  let store = EKEventStore()
  guard requestAccess(store) else {
    throw Fail("reminders access denied (System Settings > Privacy & Security > Reminders)")
  }

  let list = try findList(store, name: config.reminderList)
  print("list: \(list.title)")
  print("timezone: \(TimeZone.current.identifier) (\(utcOffset()))\n")

  let existing = try fetchReminders(store, in: list)
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
  var deleted = 0

  for entry in entries {
    let media = entry.media
    let title = media.title.resolved(config.language)

    guard let airing = Airing(media.airingSchedule.nodes) else {
      print("  skip: \(title) (no upcoming episodes)")
      skipped += 1
      continue
    }

    if let existing = existingByTitle[title] {
      if config.force {
        if needsUpdate(existing, airing: airing) {
          configure(existing, media: media, airing: airing, fmt: fmt)
          try store.save(existing, commit: false)
          print("  update: \(title)")
          updated += 1
        } else {
          print("  skip: \(title) (up to date)")
          skipped += 1
        }
        deleted += try removeDuplicates(store, of: media, keeping: title, in: existingByURL)
      } else {
        print("  skip: \(title) (already exists)")
        skipped += 1
      }
      continue
    }

    var removed = 0
    if config.force {
      removed = try removeDuplicates(store, of: media, keeping: title, in: existingByURL)
      deleted += removed
    }

    let reminder = EKReminder(eventStore: store)
    reminder.calendar = list
    reminder.title = title
    configure(reminder, media: media, airing: airing, fmt: fmt)
    try store.save(reminder, commit: false)
    print(removed > 0 ? "  replace: \(title)" : "  add: \(title)")
    created += 1
  }

  try store.commit()
  print("\ndone: \(created) created, \(updated) updated, \(deleted) deleted, \(skipped) skipped")
}

do {
  try run()
} catch {
  fputs("error: \(error)\n", stderr)
  exit(1)
}
