import XCTest
@testable import PickupCore

/// Random phone behaviour and random user actions against `CallEngine`.
///
/// Properties: never crashes; never sends dial/accept/DTMF without a user command; a hang-up is
/// always possible while a call is live and the link is up; every ended call returns to idle.
@MainActor
final class CallEngineFuzzTests: XCTestCase {
    private enum Step: CaseIterable {
        // phone
        case setupIncoming, setupOutgoing, setupAlerting, setupNone, callOn, callOff, holdOn, holdOff
        case callerID, callWaiting, callList, callListEmpty, callListWaiting, ring
        case commandOK, commandError
        case scoOpen, scoClose
        case linkDown, linkUp, linkConnecting, linkDisconnecting
        case sleep, wake
        // user
        case userAccept, userDecline, userHangUp, userEnd, userDial, userDialServiceCode, userDTMF, userMoveToPhone, userRefresh
        // time
        case tick, longWait
    }

    private struct Counters {
        var accept = 0, dial = 0, dtmf = 0, end = 0
    }

    func testRandomEventSequencesKeepTheEngineSafeAndUnstuck() throws {
        let numbers = ["+4930000123", "+4940000456", "", "0300000123"]
        try Fuzz.run("EngineSequence", iterations: 1500) { rng, seed in
            let ctx = Fuzz.context("EngineSequence", seed)
            let phone = ScriptedPhone(supportsAudio: rng.chance(0.5), takeCallsOnMac: rng.chance(0.5))
            let engine = phone.engine
            let transport = phone.transport
            var counters = Counters()
            let steps = Step.allCases

            for index in 0..<rng.int(5...60) {
                let step = rng.pick(steps)
                let before = engine.phase
                switch step {
                case .setupIncoming: transport.emit(.callSetup(.incoming))
                case .setupOutgoing: transport.emit(.callSetup(.outgoing))
                case .setupAlerting: transport.emit(.callSetup(.remoteAlerting))
                case .setupNone: transport.emit(.callSetup(.none))
                case .callOn: transport.emit(.call(true))
                case .callOff: transport.emit(.call(false))
                case .holdOn: transport.emit(.callHeld(.heldOnly))
                case .holdOff: transport.emit(.callHeld(rng.pick([.none, .activeAndHeld])))
                case .callerID: transport.emit(.callerID(rng.pick(numbers)))
                case .callWaiting: transport.emit(.callWaiting(rng.pick(numbers)))
                case .callList:
                    transport.emit(.currentCalls([HFPCall(index: 1, direction: rng.pick([.incoming, .outgoing]), status: rng.pick([.active, .held, .dialing, .alerting, .incoming, .waiting]), number: rng.pick(numbers))]))
                case .callListEmpty: transport.emit(.currentCalls([]))
                case .callListWaiting:
                    transport.emit(.currentCalls([
                        HFPCall(index: 1, direction: .incoming, status: .active, number: rng.pick(numbers)),
                        HFPCall(index: 2, direction: .incoming, status: .waiting, number: rng.pick(numbers)),
                    ]))
                case .ring: transport.emit(.ring)
                case .commandOK, .commandError:
                    let command = rng.pick([HFPCommand.accept, .endCall, .dial, .dtmf, .currentCalls, .other("AT+X")])
                    let result: CommandResult = step == .commandOK ? .ok : rng.pick([.error, .cmeError(30), .cmsError(1), .callFailure("BUSY")])
                    transport.emit(.commandCompleted(command, result))
                case .scoOpen: transport.emit(.audioConnectionChanged(isOpen: true))
                case .scoClose: transport.emit(.audioConnectionChanged(isOpen: false))
                case .linkDown: transport.emit(.linkStateChanged(.disconnected))
                case .linkUp: transport.bringUp(call: rng.chance(0.3), callSetup: rng.pick([.none, .none, .incoming]))
                case .linkConnecting: transport.emit(.linkStateChanged(.connecting))
                case .linkDisconnecting: transport.emit(.linkStateChanged(.disconnecting))
                case .sleep: engine.prepareForSleep()
                case .wake: engine.systemDidWake()
                case .userAccept: if (try? engine.accept()) != nil { counters.accept += 1 }
                case .userDecline: if (try? engine.decline()) != nil { counters.end += 1 }
                case .userHangUp: if (try? engine.hangUp()) != nil { counters.end += 1 }
                case .userEnd: if (try? engine.endCall()) != nil { counters.end += 1 }
                case .userDial:
                    if (try? engine.dial(DialNumber(rng.pick(["+4930000123", "112", "0300000123"]))!)) != nil { counters.dial += 1 }
                case .userDialServiceCode:
                    let code = DialNumber("**21*0300000123#")!
                    XCTAssertThrowsError(try engine.dial(code), ctx) // never without allowServiceCode
                case .userDTMF: if (try? engine.sendDTMF(DTMFDigit("5")!)) != nil { counters.dtmf += 1 }
                case .userMoveToPhone: _ = try? engine.transferAudioToPhone()
                case .userRefresh: engine.refreshCallList()
                case .tick: phone.advance(rng.pick([0.1, 0.5, 1, 3]))
                case .longWait: phone.advance(rng.pick([10, 30, 130]))
                }

                // Invariants after every step.
                let info = "\(ctx) step \(index) \(step) (phase \(before) -> \(engine.phase))"
                if let call = engine.call {
                    if call.phase == .ended {
                        XCTAssertNotNil(call.endReason, info)
                        XCTAssertNotNil(call.endedAt, info)
                    } else {
                        XCTAssertNil(call.endReason, info)
                        XCTAssertNil(call.endedAt, info)
                    }
                    XCTAssertGreaterThanOrEqual(call.duration(at: phone.scheduler.now) ?? 0, 0, info)
                    if call.phase == .active || call.phase == .held { XCTAssertNotNil(call.connectedAt, info) }
                }
                if engine.waitingCall != nil {
                    XCTAssertTrue(engine.phase == .active || engine.phase == .held, "waiting call without an active call \(info)")
                }
                // The engine never issues these by itself.
                XCTAssertEqual(transport.count(.acceptCallOnPhone), counters.accept, info)
                XCTAssertEqual(transport.commands.filter { if case .dial = $0 { return true } else { return false } }.count, counters.dial, info)
                XCTAssertEqual(transport.commands.filter { if case .sendDTMF = $0 { return true } else { return false } }.count, counters.dtmf, info)
                XCTAssertLessThanOrEqual(transport.count(.endCall), counters.end * 2, "at most one automatic re-send per cancelled call \(info)")
            }

            // Liveness: bring the link up, then a live call can always be ended and everything drains to idle.
            if engine.linkState != .connected {
                transport.bringUp(call: false)
            }
            if engine.phase.isLive {
                XCTAssertNoThrow(try engine.endCall(), "hang-up blocked in phase \(engine.phase) \(ctx)")
            }
            transport.emit(.call(false))
            transport.emit(.callSetup(.none))
            transport.emit(.callHeld(.none))
            phone.advance(200)
            XCTAssertEqual(engine.phase, .idle, "stuck after everything ended: \(String(describing: engine.call)) \(ctx)")
            XCTAssertNil(engine.waitingCall, ctx)
            for finished in phone.finished {
                XCTAssertNotNil(finished.endReason, ctx)
                XCTAssertEqual(finished.phase, .ended, ctx)
            }
            // After all that, a fresh call works again.
            transport.emit(.callSetup(.incoming))
            XCTAssertEqual(engine.phase, .ringing, "engine did not recover \(ctx)")
        }
    }

    func testLiveCallCanAlwaysBeEndedWhileTheLinkIsUp() {
        // Every way into a live phase, then end it.
        let routes: [(String, (ScriptedPhone) -> Void)] = [
            ("ringing", { $0.transport.emit(.callSetup(.incoming)) }),
            ("dialing by user", { try? $0.engine.dial(DialNumber("+4930000123")!) }),
            ("dialing on phone", { $0.transport.emit(.callSetup(.outgoing)) }),
            ("alerting", { $0.transport.emit(.callSetup(.remoteAlerting)) }),
            ("active", { $0.transport.emit(.call(true)) }),
            ("held", { $0.transport.emit(.call(true)); $0.transport.emit(.callHeld(.heldOnly)) }),
            ("adopted after link up", { $0.dropLink(); $0.transport.bringUp(call: true) }),
        ]
        for (name, route) in routes {
            let phone = ScriptedPhone(supportsAudio: false)
            route(phone)
            XCTAssertTrue(phone.engine.phase.isLive, name)
            XCTAssertNoThrow(try phone.engine.endCall(), name)
            XCTAssertEqual(phone.commands.last, .endCall, name)
        }
    }
}
