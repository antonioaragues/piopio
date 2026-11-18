import Foundation
import Testing
@testable import PiopioKit

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Madrid")!
    return c
}()

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

@Test func moodFollowsTheTimeOfDay() {
    #expect(PiopioMood.at(date(2026, 11, 18, 4), calendar: calendar) == .night)
    #expect(PiopioMood.at(date(2026, 11, 18, 5), calendar: calendar) == .morning)
    #expect(PiopioMood.at(date(2026, 11, 18, 11), calendar: calendar) == .morning)
    #expect(PiopioMood.at(date(2026, 11, 18, 12), calendar: calendar) == .afternoon)
    #expect(PiopioMood.at(date(2026, 11, 18, 19), calendar: calendar) == .afternoon)
    #expect(PiopioMood.at(date(2026, 11, 18, 20), calendar: calendar) == .night)
}

@Test func specialDatesWinOverTheClock() {
    #expect(PiopioMood.at(date(2026, 12, 24, 8), calendar: calendar) == .christmas)
    #expect(PiopioMood.at(date(2026, 12, 26, 23), calendar: calendar) == .christmas)
    #expect(PiopioMood.at(date(2026, 12, 27, 8), calendar: calendar) == .morning)
    #expect(PiopioMood.at(date(2026, 12, 31, 22), calendar: calendar) == .newYear)
    #expect(PiopioMood.at(date(2027, 1, 1, 9), calendar: calendar) == .newYear)
    #expect(PiopioMood.at(date(2026, 10, 31, 15), calendar: calendar) == .halloween)
    #expect(PiopioMood.at(date(2027, 2, 14, 15), calendar: calendar) == .valentine)
}

@Test func greetingNamesTheHolidayOrTheTimeOfDay() {
    #expect(PiopioMood.greeting(name: "Ana", date: date(2026, 12, 25, 9), calendar: calendar) == "Merry Christmas, Ana")
    #expect(PiopioMood.greeting(name: "Ana", date: date(2026, 10, 31, 21), calendar: calendar) == "Happy Halloween, Ana")
    #expect(PiopioMood.greeting(name: "Ana", date: date(2027, 1, 1, 1), calendar: calendar) == "Happy new year, Ana")
    // Valentine's dresses the chick up but keeps the usual greeting.
    #expect(PiopioMood.greeting(name: "Ana", date: date(2027, 2, 14, 9), calendar: calendar) == "Good morning, Ana")
    #expect(PiopioMood.greeting(name: "Ana", date: date(2026, 11, 18, 22), calendar: calendar) == "Good evening, Ana")
}

@Test func newYearWelcomesTheComingYear() {
    #expect(PiopioMood.welcomedYear(date(2026, 12, 31, 20), calendar: calendar) == 2027)
    #expect(PiopioMood.welcomedYear(date(2027, 1, 1, 10), calendar: calendar) == 2027)
    #expect(PiopioMood.newYear.lines(name: "Ana", date: date(2026, 12, 31, 20), calendar: calendar).contains("Happy 2027!"))
    #expect(PiopioMood.valentine.lines(name: "Ana", date: .now).contains("love you, Ana"))
}
