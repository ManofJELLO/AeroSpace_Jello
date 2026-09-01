private let focusFollowsMouseParserTable: [String: any ParserProtocol<FocusFollowsMouse>] = [
    "enabled": Parser(\.enabled, parseBool),
    "delay-ms": Parser(\.delayMs, parseDelayMs),
    "raise": Parser(\.raise, parseBool),
    "disable-key": Parser(\.disableKey, parseDisableKey),
]

private func parseDelayMs(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace)
        .filter(.init(backtrace, "focus-follows-mouse.delay-ms can't be negative")) { $0 >= 0 }
}

private func parseDisableKey(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<FocusFollowsMouseDisableKey> {
    let msg = "Can't parse focus-follows-mouse.disable-key. Possible values: \(FocusFollowsMouseDisableKey.unionLiteral)"
    return parseString(raw, backtrace)
        .flatMap { FocusFollowsMouseDisableKey(rawValue: $0).toResult(.init(backtrace, msg)) }
}

func parseFocusFollowsMouse(_ rawConfig: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> FocusFollowsMouse {
    parseTable(rawConfig, FocusFollowsMouse(), focusFollowsMouseParserTable, backtrace, &c)
}
