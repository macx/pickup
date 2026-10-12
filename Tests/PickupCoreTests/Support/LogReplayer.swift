import Foundation
@testable import PickupCore

/// Replays a spike log (`<ISO timestamp> [CATEGORY] message`) into a `CallEngine`.
///
/// It plays the part of IOBluetooth: raw AT lines go through `ATExchangeTracker` and
/// `HFPIndicatorMap` and come out as the `TransportEvent`s the real transport would emit.
/// User commands (`[CMD] > accept`, `> hangup`, `> dial <n>`, `> dtmf <d>`) call the engine.
/// The scheduler follows the log timestamps, so grace periods and durations are real.
/// Delegate lines are ignored (they duplicate the AT lines).
@MainActor
final class LogReplayer {
    struct Line {
        let date: Date
        let category: String
        let message: String
    }

    let transport: MockHFPTransport
    let scheduler: ManualScheduler
    let engine: CallEngine
    private(set) var finishedCalls: [CallInfo] = []
    /// Phase after every replayed line where it changed.
    private(set) var phaseChanges: [(Date, CallPhase)] = []
    private(set) var engineErrors: [Error] = []

    private var tracker = ATExchangeTracker()
    private var indicatorMap: HFPIndicatorMap?
    private let lines: [Line]
    private var cursor = 0

    init(log: String, configuration: CallEngine.Configuration = .init()) {
        lines = log.split(separator: "\n").compactMap { LogReplayer.parse(String($0)) }
        let start = lines.first?.date ?? Date()
        transport = MockHFPTransport()
        scheduler = ManualScheduler(now: start)
        engine = CallEngine(transport: transport, scheduler: scheduler, configuration: configuration)
        engine.onCallFinished = { [unowned self] call in
            self.finishedCalls.append(call)
        }
    }

    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ text: String) -> Line? {
        // 2026-10-11T11:08:46.688+02:00 [AT      ] << +CIEV: 2,1    (annotation)
        guard let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]"), open < close,
              let date = timestampFormatter.date(from: String(text[..<open]).trimmingCharacters(in: .whitespaces))
        else { return nil }
        let category = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        var message = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        // The spike appends annotations after four spaces: "    (parsed)" or "    [detail]".
        if let annotation = message.range(of: "    ") {
            message = String(message[..<annotation.lowerBound])
        }
        return Line(date: date, category: category, message: message)
    }

    /// Continues the replay up to and including `until` (or to the end), then advances the
    /// clock to `until` so pending timers (grace periods) fire.
    func replay(until: Date? = nil) {
        while cursor < lines.count {
            let line = lines[cursor]
            if let until, line.date > until { break }
            cursor += 1
            scheduler.advance(to: line.date)
            let before = engine.phase
            handle(line)
            if engine.phase != before {
                phaseChanges.append((line.date, engine.phase))
            }
        }
        if let until {
            scheduler.advance(to: until)
        }
    }

    private func handle(_ line: Line) {
        switch line.category {
        case "STATE":
            if line.message.hasPrefix("link ") {
                linkTransition(String(line.message.split(separator: " ").last ?? ""))
            }
        case "AT":
            if line.message.hasPrefix(">> ") {
                tracker.outgoing(String(line.message.dropFirst(3)), at: line.date)
            } else if line.message.hasPrefix("<< ") {
                for output in tracker.incoming(String(line.message.dropFirst(3)), at: line.date) {
                    handle(output)
                }
            }
        case "CMD":
            if line.message.hasPrefix("> ") {
                userCommand(String(line.message.dropFirst(2)))
            }
        default:
            break
        }
    }

    private func linkTransition(_ state: String) {
        switch state {
        case "connecting": transport.emit(.linkStateChanged(.connecting))
        case "connected": transport.emit(.linkStateChanged(.connected))
        case "disconnecting": transport.emit(.linkStateChanged(.disconnecting))
        case "idle", "disconnected": transport.emit(.linkStateChanged(.disconnected))
        default: break
        }
    }

    private func handle(_ output: ATExchangeTracker.Output) {
        switch output {
        case .unsolicited(.indicator(let index, let value)):
            if let indicator = indicatorMap?.indicator(index: index, value: value) {
                transport.emit(.indicator(indicator))
            }
        case .unsolicited(.ring):
            transport.emit(.ring)
        case .unsolicited(.callerID(let number)):
            transport.emit(.callerID(number))
        case .unsolicited(.callWaiting(let number)):
            transport.emit(.callWaiting(number))
        case .unsolicited, .response, .discarded:
            break
        case .completed(let exchange):
            switch exchange.command {
            case .other("AT+CIND=?"):
                indicatorMap = exchange.responses.first.flatMap(HFPIndicatorMap.init(testResponse:))
            case .other("AT+CIND?"):
                if let map = indicatorMap, let response = exchange.responses.first {
                    map.indicators(fromReadResponse: response).forEach { transport.emit(.indicator($0)) }
                }
            case .currentCalls where exchange.result.isSuccess:
                transport.emit(.currentCalls(exchange.currentCalls))
            default:
                break
            }
            transport.emit(.commandCompleted(exchange.command, exchange.result))
        }
    }

    private func userCommand(_ text: String) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        do {
            switch parts.first ?? "" {
            case "accept": try engine.accept()
            case "decline", "hangup": try engine.endCall()
            case "dial":
                guard let number = DialNumber(argument) else { return }
                // Typed by hand in the spike (like the dial pad). The logged number is abbreviated
                // with `*`, which would otherwise count as a service code.
                try engine.dial(number, allowServiceCode: true)
            case "dtmf":
                guard let character = argument.first, let digit = DTMFDigit(character) else { return }
                try engine.sendDTMF(digit)
            default:
                break // spike-only commands (clcc, status, typos)
            }
        } catch {
            engineErrors.append(error)
        }
    }
}
