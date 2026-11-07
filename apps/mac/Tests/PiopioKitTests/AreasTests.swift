import Testing
@testable import PiopioKit

@Test func areasRoundTripTheirStoredForm() {
    #expect(AreaSet(stored: nil) == .all)
    #expect(AreaSet(stored: "") == .all)
    #expect(AreaSet(stored: "agents, chat").stored == "chat,agents")
    #expect(AreaSet(stored: "chat,spaces").stored == "chat")
    #expect(AreaSet(stored: "nonsense") == .all)
    // Chat is always on (docs/spec/18 §7), also for a set saved without it.
    #expect(AreaSet(stored: "build").stored == "build,chat")
    #expect(AreaSet.switchable == [.build, .agents])
}

@Test func chatCantBeTurnedOffTheOthersCan() {
    var set = AreaSet(stored: "chat,agents")
    let agentsOff = set.set(.agents, on: false)
    #expect(agentsOff)
    #expect(!set.canTurnOff(.chat))
    let chatOff = set.set(.chat, on: false)
    #expect(!chatOff)
    #expect(set.stored == "chat")
    let buildOn = set.set(.build, on: true)
    let buildAgain = set.set(.build, on: true)
    #expect(buildOn && !buildAgain)
    #expect(set.ordered == [.build, .chat])
}

@Test func sectionsFollowTheAreas() {
    let chatOnly = AreaSet(stored: "chat")
    #expect(chatOnly.showsProjects && chatOnly.showsChats && !chatOnly.showsAgents)
    #expect(chatOnly.showsSession(chatProfile: true) && !chatOnly.showsSession(chatProfile: false))

    let buildOnly = AreaSet(stored: "build")
    #expect(buildOnly.showsProjects && buildOnly.showsChats && !buildOnly.showsAgents)
    #expect(buildOnly.showsSession(chatProfile: false) && buildOnly.showsSession(chatProfile: true))

    // Chat is always on, so projects (folders to read) and conversations show with Agents alone too.
    let agentsOnly = AreaSet(stored: "agents")
    #expect(agentsOnly.showsProjects && agentsOnly.showsChats && agentsOnly.showsAgents)
}

@Test func theWelcomeShowsOnlyOnANewInstall() {
    #expect(WelcomeGate.decide(done: false, hasHistory: false) == .show)
    #expect(WelcomeGate.decide(done: false, hasHistory: true) == .existingUser)
    #expect(WelcomeGate.decide(done: true, hasHistory: false) == .done)
    #expect(WelcomeGate.decide(done: true, hasHistory: true, forced: true) == .show)
}
