public struct MasterCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .master,
        help: master_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--workspace": workspaceSubArgParser(),
        ],
        posArgs: [newMandatoryPosArgParser(\.action, parseMasterAction, placeholder: masterActionPlaceholder)],
        conflictingOptions: [
            ["--window-id", "--workspace"],
        ],
    )

    public var action: Lateinit<MasterAction> = .uninitialized

    public init(rawArgs: [String], action: MasterAction) {
        self.commonState = .init(rawArgs.slice)
        self.action = .initialized(action)
    }

    public enum MasterAction: Equatable, Sendable {
        /// Exchange the focused window with the master. Toggles back when the focused window already is the master
        case swapWithMaster
        /// Focus the master. Focuses back into the stack when the master already has the focus
        case focusMaster
        /// Shift every window one slot forward/backward, so a different window ends up in the master area
        case rotateNext
        case rotatePrev
        /// Grow/shrink the master area by one window
        case addMaster
        case removeMaster
        case setCount(Units)
        /// In percent of the container
        case setFraction(Units)
        case setOrientation(OrientationTarget)
    }

    public enum OrientationTarget: Equatable, Sendable {
        case exact(MasterOrientation)
        /// Walk ``MasterOrientation/cycle``
        case next
        case prev
    }

    public enum Units: Equatable, Sendable {
        case set(Int)
        case add(Int)
        case subtract(Int)
    }
}

private let masterActionPlaceholder = """
    (swap-with-master|focus-master|rotate-next|rotate-prev|add-master|remove-master|\
    set-count <count>|set-fraction <percent>|set-orientation <orientation>)
    """

func parseMasterCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MasterCmdArgs> {
    parseSpecificCmdArgs(MasterCmdArgs(rawArgs: args), args)
}

private func parseMasterAction(i: PosArgParserInput) -> ParsedCliArgs<MasterCmdArgs.MasterAction> {
    switch i.arg {
        case "swap-with-master": return .succ(.swapWithMaster, advanceBy: 1)
        case "focus-master": return .succ(.focusMaster, advanceBy: 1)
        case "rotate-next": return .succ(.rotateNext, advanceBy: 1)
        case "rotate-prev": return .succ(.rotatePrev, advanceBy: 1)
        case "add-master": return .succ(.addMaster, advanceBy: 1)
        case "remove-master": return .succ(.removeMaster, advanceBy: 1)
        case "set-count", "set-fraction":
            let subcommand = i.arg
            guard let raw = i.getOrNil(relativeIndex: 1), !raw.isCliDashFlag || isNegativeNumber(raw) else {
                return .fail("'\(subcommand)' requires an argument. Expected: [+|-]<number>", advanceBy: 1)
            }
            guard let units = parseUnits(raw) else {
                return .fail("Can't parse '\(raw)'. Expected: [+|-]<number>", advanceBy: 2)
            }
            return .succ(subcommand == "set-count" ? .setCount(units) : .setFraction(units), advanceBy: 2)
        case "set-orientation":
            guard let raw = i.getOrNil(relativeIndex: 1), !raw.isCliDashFlag else {
                let msg = "'set-orientation' requires an argument. " +
                    "Possible values: \(MasterOrientation.unionLiteral), next, prev"
                return .fail(msg, advanceBy: 1)
            }
            let target: MasterCmdArgs.OrientationTarget
            switch raw {
                case "next": target = .next
                case "prev": target = .prev
                default:
                    guard let orientation = MasterOrientation(rawValue: raw) else {
                        let msg = "Can't parse '\(raw)'\nPossible values: \(MasterOrientation.unionLiteral), next, prev"
                        return .fail(msg, advanceBy: 2)
                    }
                    target = .exact(orientation)
            }
            return .succ(.setOrientation(target), advanceBy: 2)
        default:
            return .fail("Can't parse '\(i.arg)'\nPossible values: \(masterActionPlaceholder)", advanceBy: 1)
    }
}

private func isNegativeNumber(_ raw: String) -> Bool {
    var iter = raw.makeIterator()
    return iter.next() == "-" && iter.next()?.isNumber == true
}

private func parseUnits(_ raw: String) -> MasterCmdArgs.Units? {
    guard let number = Int(raw.removePrefix("+").removePrefix("-")) else { return nil }
    return switch true {
        case raw.starts(with: "+"): .add(number)
        case raw.starts(with: "-"): .subtract(number)
        default: .set(number)
    }
}
