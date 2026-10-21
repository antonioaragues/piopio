import AppKit
import Contacts
import EventKit
import PiopioKit

/// Apple apps as agent tools (docs/spec/06-agents §4.1), answering the engine's `app.tool` reverse requests
/// (03-engine-protocol §3.12). Each call runs with this app's permissions; macOS asks once per app (Reminders,
/// Calendars, Contacts, and automation of Notes and Music). The agent's allowed groups are checked again here.
/// Changes answer with a result card and the call that undoes them (§4.2).
actor AppleTools {
    static let shared = AppleTools()

    private let events = EKEventStore()
    private let contacts = CNContactStore()

    /// One reply: what the model reads, a card, and how to undo.
    struct Reply {
        var ok = true
        var output: String
        var card: (kind: String, title: String, detail: String?)?
        var undo: (name: String, args: [String: JSONValue], title: String)?

        static func fail(_ text: String) -> Reply { Reply(ok: false, output: text) }

        var json: JSONValue {
            var o: [String: JSONValue] = ["ok": .bool(ok), "output": .string(output)]
            if let card {
                var c: [String: JSONValue] = ["kind": .string(card.kind), "title": .string(card.title)]
                if let d = card.detail { c["detail"] = .string(d) }
                o["card"] = .object(c)
            }
            if let undo { o["undo"] = .object(["name": .string(undo.name), "args": .object(undo.args), "title": .string(undo.title)]) }
            return .object(o)
        }
    }

    func handle(_ params: JSONValue) async -> JSONValue {
        let name = params["name"]?.stringValue ?? ""
        let args = params["args"] ?? .object([:])
        let groups = params["groups"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard let group = Self.group(of: name), groups.contains(group) else {
            return Reply.fail("This agent isn't allowed to use \(name).").json
        }
        do {
            return try await run(name, args, shortcuts: params["shortcuts"]?.arrayValue?.compactMap(\.stringValue) ?? []).json
        } catch {
            return Reply.fail((error as? ToolError)?.message ?? error.localizedDescription).json
        }
    }

    static func group(of name: String) -> String? {
        for g in ["reminders", "calendar", "contacts", "notes", "music"] where name.hasPrefix("apple_\(g)_") { return g }
        return name.hasPrefix("shortcuts_") ? "shortcuts" : nil
    }

    struct ToolError: Error { let message: String }

    private func run(_ name: String, _ a: JSONValue, shortcuts: [String]) async throws -> Reply {
        switch name {
        case "apple_reminders_lists": return try await reminderLists()
        case "apple_reminders_list": return try await listReminders(a)
        case "apple_reminders_create": return try await createReminder(a)
        case "apple_reminders_complete": return try await completeReminder(a)
        case "apple_reminders_update": return try await updateReminder(a)
        case "apple_reminders_delete": return try await deleteReminder(a)
        case "apple_calendar_calendars": return try await calendars()
        case "apple_calendar_events": return try await listEvents(a)
        case "apple_calendar_create": return try await createEvent(a)
        case "apple_calendar_update": return try await updateEvent(a)
        case "apple_calendar_delete": return try await deleteEvent(a)
        case "apple_contacts_find": return try await findContacts(a)
        case "apple_notes_search": return try await searchNotes(a)
        case "apple_notes_read": return try await readNote(a)
        case "apple_notes_create": return try await createNote(a)
        case "apple_notes_append": return try await appendNote(a)
        case "apple_notes_delete": return try await deleteNote(a)
        case "apple_notes_set": return try await setNote(a)
        case "apple_music_now": return try await musicNow()
        case "apple_music_play": return try await musicPlay(a)
        case "apple_music_control": return try await musicControl(a)
        case "shortcuts_run": return try await runShortcut(a, allowed: shortcuts)
        default: throw ToolError(message: "Unknown tool \(name).")
        }
    }

    // MARK: Permissions

    private func reminderAccess() async throws {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return }
        guard (try? await events.requestFullAccessToReminders()) == true else {
            throw ToolError(message: "Piopio doesn't have access to Reminders. The owner can allow it in System Settings › Privacy & Security › Reminders.")
        }
    }

    private func calendarAccess() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
        guard (try? await events.requestFullAccessToEvents()) == true else {
            throw ToolError(message: "Piopio doesn't have access to Calendars. The owner can allow it in System Settings › Privacy & Security › Calendars.")
        }
    }

    // MARK: Reminders

    private func reminderLists() async throws -> Reply {
        try await reminderAccess()
        let lists = events.calendars(for: .reminder)
        let def = events.defaultCalendarForNewReminders()?.calendarIdentifier
        return Reply(output: lists.map { "- \($0.title)\($0.calendarIdentifier == def ? " (default)" : "")" }.joined(separator: "\n"))
    }

    private func reminderList(_ name: String?) throws -> EKCalendar? {
        guard let name, !name.isEmpty else { return events.defaultCalendarForNewReminders() }
        guard let list = events.calendars(for: .reminder).first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw ToolError(message: "No reminder list “\(name)”. Lists: \(events.calendars(for: .reminder).map(\.title).joined(separator: ", ")).")
        }
        return list
    }

    /// EventKit's callback hands reminders across threads; they're only used inside this actor afterwards.
    private struct Found: @unchecked Sendable { let reminders: [EKReminder] }

    private func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { (cont: CheckedContinuation<Found, Never>) in
            events.fetchReminders(matching: predicate) { cont.resume(returning: Found(reminders: $0 ?? [])) }
        }.reminders
    }

    private func listReminders(_ a: JSONValue) async throws -> Reply {
        try await reminderAccess()
        let lists = try a["list"]?.stringValue.map { [try reminderList($0)!] }
        let now = Date.now
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let predicate: NSPredicate = switch a["filter"]?.stringValue ?? "open" {
        case "due": events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: lists)
        case "overdue": events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: now, calendars: lists)
        case "completed": events.predicateForCompletedReminders(withCompletionDateStarting: Calendar.current.date(byAdding: .day, value: -30, to: now), ending: now, calendars: lists)
        default: events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        }
        let limit = Int(a["limit"]?.numberValue ?? 50)
        let found = await fetch(predicate).sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
        if found.isEmpty { return Reply(output: "No reminders.") }
        let lines = found.prefix(limit).map { r in
            "- [\(r.calendarItemIdentifier)] \(r.title ?? "")\(Self.due(r).map { " · due \($0)" } ?? "") · \(r.calendar.title)\(r.isCompleted ? " · done" : "")"
        }
        return Reply(output: lines.joined(separator: "\n") + (found.count > limit ? "\n(\(found.count - limit) more)" : ""))
    }

    private func reminder(_ a: JSONValue) throws -> EKReminder {
        guard let id = a["id"]?.stringValue, let r = events.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolError(message: "No reminder with that id (list them first).")
        }
        return r
    }

    private func createReminder(_ a: JSONValue) async throws -> Reply {
        try await reminderAccess()
        let r = EKReminder(eventStore: events)
        r.title = a["title"]?.stringValue ?? "Reminder"
        r.calendar = try reminderList(a["list"]?.stringValue)
        if let due = a["due"]?.stringValue { try setDue(r, due) }
        r.notes = a["notes"]?.stringValue
        r.priority = switch a["priority"]?.stringValue { case "high": 1; case "medium": 5; case "low": 9; default: 0 }
        try events.save(r, commit: true)
        let when = Self.due(r)
        return Reply(
            output: "Created [\(r.calendarItemIdentifier)] \(r.title ?? "")\(when.map { " due \($0)" } ?? "") in \(r.calendar.title).",
            card: ("reminder", r.title ?? "Reminder", [when.map { "Due \($0)" }, r.calendar.title].compactMap { $0 }.joined(separator: " · ")),
            undo: ("apple_reminders_delete", ["id": .string(r.calendarItemIdentifier)], "creating “\(r.title ?? "")”")
        )
    }

    private func completeReminder(_ a: JSONValue) async throws -> Reply {
        try await reminderAccess()
        let r = try reminder(a)
        let was = r.isCompleted
        r.isCompleted = a["completed"].flatMap { if case .bool(let b) = $0 { b } else { nil } } ?? true
        try events.save(r, commit: true)
        return Reply(
            output: "\(r.title ?? "") is \(r.isCompleted ? "done" : "not done").",
            card: ("reminder", r.isCompleted ? "Done: \(r.title ?? "")" : "Not done: \(r.title ?? "")", r.calendar.title),
            undo: ("apple_reminders_complete", ["id": .string(r.calendarItemIdentifier), "completed": .bool(was)], "ticking “\(r.title ?? "")”")
        )
    }

    private func updateReminder(_ a: JSONValue) async throws -> Reply {
        try await reminderAccess()
        let r = try reminder(a)
        let before: [String: JSONValue] = [
            "id": .string(r.calendarItemIdentifier), "title": .string(r.title ?? ""), "due": .string(Self.iso(r.dueDateComponents)),
            "list": .string(r.calendar.title), "notes": .string(r.notes ?? ""),
        ]
        let oldDue = Self.due(r)
        if let t = a["title"]?.stringValue { r.title = t }
        if let due = a["due"]?.stringValue { try setDue(r, due) }
        if let list = a["list"]?.stringValue { r.calendar = try reminderList(list) }
        if let notes = a["notes"]?.stringValue { r.notes = notes.isEmpty ? nil : notes }
        try events.save(r, commit: true)
        let newDue = Self.due(r)
        return Reply(
            output: "Updated [\(r.calendarItemIdentifier)] \(r.title ?? "")\(newDue.map { " due \($0)" } ?? "") in \(r.calendar.title).",
            card: ("reminder", r.title ?? "Reminder", oldDue != newDue ? "Due \(oldDue ?? "none") → \(newDue ?? "none")" : r.calendar.title),
            undo: ("apple_reminders_update", before, "changing “\(r.title ?? "")”")
        )
    }

    private func deleteReminder(_ a: JSONValue) async throws -> Reply {
        try await reminderAccess()
        let r = try reminder(a)
        try events.remove(r, commit: true)
        return Reply(output: "Deleted \(r.title ?? "").")
    }

    /// "" clears the due date.
    private func setDue(_ r: EKReminder, _ text: String) throws {
        r.alarms?.forEach { r.removeAlarm($0) }
        guard !text.isEmpty else { r.dueDateComponents = nil; return }
        guard let (date, hasTime) = Self.parse(text) else { throw ToolError(message: "Give the date as 2026-10-23 or 2026-10-23T09:00.") }
        let units: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        r.dueDateComponents = Calendar.current.dateComponents(units, from: date)
        if hasTime { r.addAlarm(EKAlarm(absoluteDate: date)) }
    }

    private static func due(_ r: EKReminder) -> String? {
        guard let c = r.dueDateComponents, let d = Calendar.current.date(from: c) else { return nil }
        return c.hour == nil ? d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    private static func iso(_ c: DateComponents?) -> String {
        guard let c, let d = Calendar.current.date(from: c) else { return "" }
        return c.hour == nil ? localISO(d, time: false) : localISO(d, time: true)
    }

    // MARK: Calendar

    private func calendars() async throws -> Reply {
        try await calendarAccess()
        let def = events.defaultCalendarForNewEvents?.calendarIdentifier
        return Reply(output: events.calendars(for: .event).map { "- \($0.title)\($0.calendarIdentifier == def ? " (default)" : "")\($0.allowsContentModifications ? "" : " (read-only)")" }.joined(separator: "\n"))
    }

    private func eventCalendar(_ name: String?) throws -> EKCalendar? {
        guard let name, !name.isEmpty else { return events.defaultCalendarForNewEvents }
        guard let c = events.calendars(for: .event).first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw ToolError(message: "No calendar “\(name)”.")
        }
        return c
    }

    private func listEvents(_ a: JSONValue) async throws -> Reply {
        try await calendarAccess()
        guard let from = a["from"]?.stringValue.flatMap(Self.parse)?.0, let to = a["to"]?.stringValue.flatMap(Self.parse)?.0, to > from else {
            throw ToolError(message: "Give from and to as dates or date-times, to after from.")
        }
        let cals = try a["calendar"]?.stringValue.map { [try eventCalendar($0)!] }
        let found = events.events(matching: events.predicateForEvents(withStart: from, end: to, calendars: cals)).sorted { $0.startDate < $1.startDate }
        if found.isEmpty { return Reply(output: "Nothing in that time: it's free.") }
        return Reply(output: found.prefix(100).map { e in
            "- [\(e.eventIdentifier ?? "")] \(e.title ?? "") · \(Self.span(e)) · \(e.calendar.title)\(e.location.map { " · \($0)" } ?? "")"
        }.joined(separator: "\n"))
    }

    private func event(_ a: JSONValue) throws -> EKEvent {
        guard let id = a["id"]?.stringValue, let e = events.event(withIdentifier: id) else { throw ToolError(message: "No event with that id (list events first).") }
        return e
    }

    private func createEvent(_ a: JSONValue) async throws -> Reply {
        try await calendarAccess()
        guard let (start, startTime) = a["start"]?.stringValue.flatMap(Self.parse), let (end, _) = a["end"]?.stringValue.flatMap(Self.parse) else {
            throw ToolError(message: "Give start and end as 2026-10-23T18:00 (or dates for an all-day event).")
        }
        let e = EKEvent(eventStore: events)
        e.title = a["title"]?.stringValue ?? "Event"
        e.calendar = try eventCalendar(a["calendar"]?.stringValue)
        e.startDate = start
        e.endDate = startTime ? max(end, start) : max(end, start.addingTimeInterval(86_400))
        e.isAllDay = !startTime
        e.location = a["location"]?.stringValue
        e.notes = a["notes"]?.stringValue
        try events.save(e, span: .thisEvent, commit: true)
        return Reply(
            output: "Created [\(e.eventIdentifier ?? "")] \(e.title ?? "") \(Self.span(e)) in \(e.calendar.title).",
            card: ("event", e.title ?? "Event", "\(Self.span(e)) · \(e.calendar.title)"),
            undo: ("apple_calendar_delete", ["id": .string(e.eventIdentifier ?? "")], "creating “\(e.title ?? "")”")
        )
    }

    private func updateEvent(_ a: JSONValue) async throws -> Reply {
        try await calendarAccess()
        let e = try event(a)
        let before: [String: JSONValue] = [
            "id": .string(e.eventIdentifier ?? ""), "title": .string(e.title ?? ""), "start": .string(Self.localISO(e.startDate, time: true)),
            "end": .string(Self.localISO(e.endDate, time: true)), "location": .string(e.location ?? ""),
        ]
        let old = Self.span(e)
        if let t = a["title"]?.stringValue { e.title = t }
        let duration = e.endDate.timeIntervalSince(e.startDate)
        if let s = a["start"]?.stringValue.flatMap(Self.parse)?.0 { e.startDate = s; e.endDate = s.addingTimeInterval(duration) }
        if let end = a["end"]?.stringValue.flatMap(Self.parse)?.0 { e.endDate = max(end, e.startDate) }
        if let l = a["location"]?.stringValue { e.location = l.isEmpty ? nil : l }
        try events.save(e, span: .thisEvent, commit: true)
        let new = Self.span(e)
        return Reply(
            output: "Updated [\(e.eventIdentifier ?? "")] \(e.title ?? "") \(new).",
            card: ("event", e.title ?? "Event", old == new ? e.calendar.title : "\(old) → \(new)"),
            undo: ("apple_calendar_update", before, "changing “\(e.title ?? "")”")
        )
    }

    private func deleteEvent(_ a: JSONValue) async throws -> Reply {
        try await calendarAccess()
        let e = try event(a)
        try events.remove(e, span: .thisEvent, commit: true)
        return Reply(output: "Deleted \(e.title ?? "").")
    }

    private static func span(_ e: EKEvent) -> String {
        if e.isAllDay { return e.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " (all day)" }
        let day = e.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(day) \(e.startDate.formatted(date: .omitted, time: .shortened))–\(e.endDate.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Contacts

    private func findContacts(_ a: JSONValue) async throws -> Reply {
        if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
            guard (try? await contacts.requestAccess(for: .contacts)) == true else {
                throw ToolError(message: "Piopio doesn't have access to Contacts. The owner can allow it in System Settings › Privacy & Security › Contacts.")
            }
        }
        let query = a["query"]?.stringValue ?? ""
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactBirthdayKey].map { $0 as CNKeyDescriptor }
        var found = (try? contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)) ?? []
        if found.isEmpty, query.contains("@") { found = (try? contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: query), keysToFetch: keys)) ?? [] }
        if found.isEmpty, query.contains(where: \.isNumber) { found = (try? contacts.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query)), keysToFetch: keys)) ?? [] }
        if found.isEmpty { return Reply(output: "Nobody matches “\(query)”.") }
        return Reply(output: found.prefix(10).map { c in
            let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let parts = [
                c.organizationName.isEmpty ? nil : c.organizationName,
                c.emailAddresses.isEmpty ? nil : c.emailAddresses.map { $0.value as String }.joined(separator: ", "),
                c.phoneNumbers.isEmpty ? nil : c.phoneNumbers.map(\.value.stringValue).joined(separator: ", "),
                c.birthday.flatMap { Calendar.current.date(from: $0) }.map { "birthday \($0.formatted(.dateTime.day().month(.wide)))" },
            ].compactMap { $0 }
            return "- \(name.isEmpty ? c.organizationName : name)\(parts.isEmpty ? "" : ": " + parts.joined(separator: " · "))"
        }.joined(separator: "\n"))
    }

    // MARK: Notes and Music (AppleScript; arguments are passed as argv, never spliced into the script)

    private func osascript(_ lines: [String], _ argv: [String] = []) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv"] + lines.flatMap { ["-e", $0] } + ["-e", "end run"] + argv
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if message.contains("-1743") { throw ToolError(message: "Piopio isn't allowed to control that app. The owner can allow it in System Settings › Privacy & Security › Automation.") }
            throw ToolError(message: message.isEmpty ? "The script failed." : message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }

    private func searchNotes(_ a: JSONValue) async throws -> Reply {
        let limit = Int(a["limit"]?.numberValue ?? 20)
        let text = try await osascript([
            "set q to item 1 of argv", "set out to \"\"",
            "tell application \"Notes\"",
            "repeat with n in (notes whose name contains q or plaintext contains q)",
            "set out to out & (id of n) & tab & (name of n) & linefeed",
            "end repeat", "end tell", "return out",
        ], [a["query"]?.stringValue ?? ""])
        let rows = text.split(separator: "\n").prefix(limit).map { row -> String in
            let parts = row.split(separator: "\t", maxSplits: 1)
            return "- [\(parts.first ?? "")] \(parts.count > 1 ? String(parts[1]) : "")"
        }
        return Reply(output: rows.isEmpty ? "No notes match." : rows.joined(separator: "\n"))
    }

    private func readNote(_ a: JSONValue) async throws -> Reply {
        let text = try await osascript(["tell application \"Notes\" to tell note id (item 1 of argv) to return (name) & linefeed & linefeed & (plaintext)"], [a["id"]?.stringValue ?? ""])
        return Reply(output: String(text.prefix(20_000)))
    }

    private func createNote(_ a: JSONValue) async throws -> Reply {
        let title = a["title"]?.stringValue ?? "Note"
        let body = "<h1>\(Self.html(title))</h1>" + Self.html(a["body"]?.stringValue ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "<div>\($0.isEmpty ? "<br>" : $0)</div>" }.joined()
        let folder = a["folder"]?.stringValue ?? ""
        let id = try await osascript([
            "set b to item 1 of argv", "set f to item 2 of argv",
            "tell application \"Notes\"",
            "if f is \"\" then", "set n to make new note with properties {body:b}",
            "else", "set n to make new note at folder f with properties {body:b}", "end if",
            "return id of n", "end tell",
        ], [body, folder])
        return Reply(output: "Created note [\(id)] \(title).", card: ("note", title, folder.isEmpty ? "Notes" : folder), undo: ("apple_notes_delete", ["id": .string(id)], "creating the note “\(title)”"))
    }

    private func appendNote(_ a: JSONValue) async throws -> Reply {
        let id = a["id"]?.stringValue ?? ""
        let old = try await osascript(["tell application \"Notes\" to return body of note id (item 1 of argv)"], [id])
        let added = Self.html(a["text"]?.stringValue ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "<div>\($0.isEmpty ? "<br>" : $0)</div>" }.joined()
        _ = try await osascript(["tell application \"Notes\" to set body of note id (item 1 of argv) to (item 2 of argv)"], [id, old + added])
        let name = try await osascript(["tell application \"Notes\" to return name of note id (item 1 of argv)"], [id])
        return Reply(output: "Added to \(name).", card: ("note", "Added to “\(name)”", a["text"]?.stringValue), undo: ("apple_notes_set", ["id": .string(id), "body": .string(old)], "adding to “\(name)”"))
    }

    private func deleteNote(_ a: JSONValue) async throws -> Reply {
        _ = try await osascript(["tell application \"Notes\" to delete note id (item 1 of argv)"], [a["id"]?.stringValue ?? ""])
        return Reply(output: "Deleted the note.")
    }

    private func setNote(_ a: JSONValue) async throws -> Reply {
        _ = try await osascript(["tell application \"Notes\" to set body of note id (item 1 of argv) to (item 2 of argv)"], [a["id"]?.stringValue ?? "", a["body"]?.stringValue ?? ""])
        return Reply(output: "Restored the note.")
    }

    private func musicNow() async throws -> Reply {
        let text = try await osascript([
            "tell application \"Music\"",
            "if player state is playing then return (name of current track) & \" — \" & (artist of current track)",
            "return \"Nothing is playing.\"", "end tell",
        ])
        return Reply(output: text)
    }

    private func musicPlay(_ a: JSONValue) async throws -> Reply {
        let text = try await osascript([
            "set q to item 1 of argv",
            "tell application \"Music\"",
            "if exists (playlist q) then", "play playlist q", "return \"Playing the playlist \" & q", "end if",
            "set found to (tracks of library playlist 1 whose name contains q or artist contains q or album contains q)",
            "if found is {} then return \"\"",
            "play item 1 of found",
            "return (name of current track) & \" — \" & (artist of current track)", "end tell",
        ], [a["query"]?.stringValue ?? ""])
        if text.isEmpty { return .fail("Nothing in the library matches that.") }
        return Reply(output: "Playing: \(text)", card: ("music", "Playing", text))
    }

    private func musicControl(_ a: JSONValue) async throws -> Reply {
        let command = switch a["action"]?.stringValue { case "pause": "pause"; case "next": "next track"; case "previous": "previous track"; default: "play" }
        _ = try await osascript(["tell application \"Music\" to \(command)"])
        return Reply(output: "Done: \(command).")
    }

    // MARK: Shortcuts

    private func runShortcut(_ a: JSONValue, allowed: [String]) async throws -> Reply {
        guard let name = a["name"]?.stringValue, allowed.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return .fail("Only these shortcuts are allowed: \(allowed.joined(separator: ", ")).")
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "piopio-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appending(path: "out.txt")
        var arguments = ["run", name, "--output-path", output.path, "--output-type", "public.plain-text"]
        if let input = a["input"]?.stringValue {
            let file = dir.appending(path: "in.txt")
            try input.write(to: file, atomically: true, encoding: .utf8)
            arguments += ["--input-path", file.path]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = arguments
        let err = Pipe()
        p.standardError = err
        try p.run()
        await Task.detached { p.waitUntilExit() }.value
        guard p.terminationStatus == 0 else {
            return .fail("The shortcut failed: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let result = (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Reply(output: result.isEmpty ? "Ran “\(name)”." : String(result.prefix(10_000)), card: ("shortcut", "Ran “\(name)”", result.isEmpty ? nil : String(result.prefix(200))))
    }

    // MARK: Dates

    /// "2026-10-23", "2026-10-23T09:00", "2026-10-23 09:00", or ISO 8601 with an offset; local time otherwise.
    /// Returns the date and whether it had a time.
    static func parse(_ text: String) -> (Date, Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let d = try? Date(t, strategy: .iso8601) { return (d, true) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for (format, time) in [("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false)] {
            f.dateFormat = format
            if let d = f.date(from: t) { return (d, time) }
        }
        return nil
    }

    static func localISO(_ d: Date, time: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = time ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
