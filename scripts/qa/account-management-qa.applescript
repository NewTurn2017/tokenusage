on findIdentifier(elements, targetIdentifier)
    repeat with candidate in elements
        try
            tell application "System Events"
                set candidateIdentifier to value of attribute "AXIdentifier" of candidate
            end tell
            if candidateIdentifier is targetIdentifier then return contents of candidate
        end try
    end repeat
    return missing value
end findIdentifier

on requireIdentifier(elements, targetIdentifier)
    set candidate to my findIdentifier(elements, targetIdentifier)
    if candidate is missing value then
        error "missing accessibility element: " & targetIdentifier
    end if
    return candidate
end requireIdentifier

on requireDescription(element, expected)
    set candidateDescription to ""
    set candidateTitle to ""
    set candidateValue to ""
    try
        tell application "System Events" to set candidateDescription to value of attribute "AXDescription" of element
    end try
    try
        tell application "System Events" to set candidateTitle to value of attribute "AXTitle" of element
    end try
    try
        tell application "System Events" to set candidateValue to value of attribute "AXValue" of element
    end try
    set candidateText to (candidateDescription as text) & " " & (candidateTitle as text) & " " & (candidateValue as text)
    ignoring case
        if candidateText contains expected then return candidateText
    end ignoring
    error "expected accessibility value was missing: " & expected
end requireDescription

on appendAction(actions, actionText)
    set end of actions to actionText
end appendAction

on run argv
    set expectedProfile to "codex2"
    if (count argv) is 1 then set expectedProfile to item 1 of argv
    if (count argv) > 1 then error "usage: account-management-qa.applescript [expected-profile]"

    set actions to {}
    tell application "System Events"
        if not (exists process "TokenUsageApp") then error "TokenUsageApp is not running"
        tell process "TokenUsageApp"
            set tokenItems to menu bar items of menu bar 1 whose description is "Token Usage status"
            if (count tokenItems) is not 1 then error "Token Usage status item was not uniquely identifiable"

            set controls to entire contents
            set popoverContent to my findIdentifier(controls, "usage-popover-window")
            if popoverContent is missing value then
                click item 1 of tokenItems
                set controls to entire contents
                my requireIdentifier(controls, "usage-popover-window")
            end if

            set accountPicker to my requireIdentifier(controls, "codex-profile-picker")
            my requireDescription(accountPicker, expectedProfile)
            my appendAction(actions, "verified account picker value " & expectedProfile)

            set saveLogin to my requireIdentifier(controls, "save-current-profile")
            perform action "AXPress" of saveLogin
            set controls to entire contents
            my requireIdentifier(controls, "codex-profile-name")
            my requireIdentifier(controls, "confirm-save-current-profile")
            set cancelSave to my requireIdentifier(controls, "cancel-save-current-profile")
            my appendAction(actions, "verified save current login editor")
            perform action "AXPress" of cancelSave

            set controls to entire contents
            set newLogin to my requireIdentifier(controls, "add-account")
            perform action "AXPress" of newLogin
            set controls to entire contents
            my requireIdentifier(controls, "new-codex-profile-name")
            my requireIdentifier(controls, "confirm-new-codex-login")
            set cancelLogin to my requireIdentifier(controls, "cancel-new-codex-login")
            my appendAction(actions, "verified new login editor")
            perform action "AXPress" of cancelLogin

            set controls to entire contents
            set profileActions to my requireIdentifier(controls, "codex-profile-actions")
            perform action "AXPress" of profileActions
            try
                set deleteProfile to menu item 1 of menu 1 of profileActions
                set deleteTitle to name of deleteProfile
            on error
                error "missing accessibility element: delete-selected-profile"
            end try
            ignoring case
                if deleteTitle does not contain "Delete" or deleteTitle does not contain expectedProfile then
                    error "unexpected delete action: " & deleteTitle
                end if
            end ignoring
            my appendAction(actions, "verified delete action " & deleteTitle)
            key code 53

            set controls to entire contents
            set quitButton to my requireIdentifier(controls, "quit")
            perform action "AXPress" of quitButton
        end tell
    end tell

    set AppleScript's text item delimiters to linefeed
    return actions as text
end run
