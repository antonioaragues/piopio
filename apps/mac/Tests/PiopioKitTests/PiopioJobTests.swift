import Testing
@testable import PiopioKit

@Test func jobsGoRoundInOrder() {
    var job = PiopioJob.secretary
    var seen: [PiopioJob] = []
    for _ in PiopioJob.allCases {
        seen.append(job)
        job = job.next
    }
    #expect(seen == PiopioJob.allCases)
    #expect(job == .secretary)
}

@Test func templatesDressItForTheirJob() {
    #expect(PiopioJob.forTemplate("daily-briefing") == .secretary)
    #expect(PiopioJob.forTemplate("research-watcher") == .detective)
    #expect(PiopioJob.forTemplate("habit-coach") == .coach)
    #expect(PiopioJob.forTemplate("something-else") == nil)
    #expect(PiopioJob.forTemplate(nil) == nil)
}

@Test func everyJobHasWords() {
    for job in PiopioJob.allCases {
        #expect(!job.title.isEmpty && !job.line.isEmpty && !job.example.isEmpty)
    }
}
