/// What a click on the menu bar icon (or the global shortcut) does.
///
/// While a call is live the call panel is the only useful place: dialing is blocked during a call
/// (three-way calling is not supported), so the click brings the call panel to the front instead of
/// opening the dialer popover.
enum StatusItemClick: Equatable {
    case closePopover
    case focusCallPanel
    case showPopover

    static func action(popoverShown: Bool, callIsLive: Bool, callPanelVisible: Bool) -> StatusItemClick {
        if popoverShown { return .closePopover }
        if callIsLive && callPanelVisible { return .focusCallPanel }
        return .showPopover
    }
}
