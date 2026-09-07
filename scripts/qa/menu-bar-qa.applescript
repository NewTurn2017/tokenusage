on run argv
    set actionLog to missing value
    set screenshotsDirectory to missing value
    set requireLiveQuotas to false
    set expectedProfiles to {}
    set argumentIndex to 1
    repeat while argumentIndex <= count argv
        set argument to item argumentIndex of argv
        if argument is "--action-log" then
            if argumentIndex = count argv then error "--action-log requires a path"
            set argumentIndex to argumentIndex + 1
            set actionLog to item argumentIndex of argv
        else if argument is "--screenshots" then
            if argumentIndex = count argv then error "--screenshots requires a path"
            set argumentIndex to argumentIndex + 1
            set screenshotsDirectory to item argumentIndex of argv
        else if argument is "--require-live-quotas" then
            set requireLiveQuotas to true
        else if argument is "--expected-profile" then
            if argumentIndex = count argv then error "--expected-profile requires a name"
            set argumentIndex to argumentIndex + 1
            set expectedProfile to item argumentIndex of argv
            if expectedProfile starts with "--" then error "--expected-profile requires a name"
            if expectedProfile is "" then error "--expected-profile requires a name"
            if expectedProfile is in expectedProfiles then error "duplicate --expected-profile: " & expectedProfile
            set end of expectedProfiles to expectedProfile
        else
            error "unknown argument: " & argument
        end if
        set argumentIndex to argumentIndex + 1
    end repeat
    if actionLog is missing value then error "--action-log is required"
    if screenshotsDirectory is missing value then error "--screenshots is required"
    if (count expectedProfiles) is 0 then error "--expected-profile is required"

    do shell script "/bin/mkdir -p " & quoted form of screenshotsDirectory
    my logAction(actionLog, "locate menu bar status item")

    tell application "System Events"
        if not (exists process "TokenUsageApp") then error "TokenUsageApp is not running"
        tell process "TokenUsageApp"
            set frontmost to true
            set tokenItems to menu bar items of menu bar 1 whose description is "Token Usage status"
            if (count tokenItems) is not 1 then error "Token Usage status item was not uniquely identifiable"
            set axElements to entire contents
            set popoverContent to my findIdentifier(axElements, "usage-popover-window")
            if popoverContent is missing value then
                click item 1 of tokenItems
                set axElements to entire contents
                set popoverContent to my requireIdentifier(axElements, "usage-popover-window", "usage popover content")
            end if
            my requireDescription(popoverContent, "Token Usage quota window", "usage popover label")

            my requireQuota(axElements, "claude-5-hour-quota", "Claude 5 hour", requireLiveQuotas)
            my requireQuota(axElements, "claude-weekly-quota", "Claude weekly", requireLiveQuotas)
            my requireQuota(axElements, "claude-fable-weekly-quota", "Claude Fable weekly", requireLiveQuotas)
            my requireIdentifier(axElements, "openrouter-section", "OpenRouter section")
            my requireAction(axElements, "refresh-now", "Refresh Now action")
            set profilePicker to my requireIdentifier(axElements, "codex-profile-picker", "active Codex account")
            my requireIdentifier(axElements, "codex-profile-quota-scroll", "Codex profile quota list")
            my requireAction(axElements, "save-current-profile", "Save current Codex login")
            my requireAction(axElements, "add-account", "Start a new Codex login")
            my requireAction(axElements, "quit", "Quit Token Usage action")

            set profileRows to my allProfileQuotaRows(axElements)
            set expectedRows to my requireProfileQuotaRows(profileRows, expectedProfiles, requireLiveQuotas, actionLog)
            my requireExactlyOneActiveProfile(profileRows)
            set originalActiveProfile to my profileNameFromPicker(profilePicker, expectedProfiles)
            set selectedProfile to my selectionTarget(expectedProfiles, originalActiveProfile)

            set didSelectProfile to false
            try
                perform action "AXPress" of profilePicker
                set menuElements to entire contents
                set selectedProfileItem to my requireName(menuElements, selectedProfile, "selected Codex profile")
                perform action "AXPress" of selectedProfileItem
                set didSelectProfile to true
                set updatedElements to entire contents
                set activeProfile to my requireIdentifier(updatedElements, "codex-profile-picker", "active Codex account")
                my requireDescription(activeProfile, selectedProfile, "active Codex account value")
                set updatedProfileRows to my allProfileQuotaRows(updatedElements)
                my requireProfileQuotaRows(updatedProfileRows, expectedProfiles, requireLiveQuotas, actionLog)
                my requireExactlyOneActiveProfile(updatedProfileRows)
                my requireActiveProfileRow(updatedProfileRows, selectedProfile)
                my logAction(actionLog, "verified selected profile " & selectedProfile)
                my rejectForbidden(menuElements)
                my restoreOriginalProfile(originalActiveProfile, actionLog)
                set didSelectProfile to false
            on error originalError number originalNumber
                if didSelectProfile then
                    try
                        my restoreOriginalProfile(originalActiveProfile, actionLog)
                    on error restoreError
                        error "failed to restore original active profile after QA failure: " & restoreError
                    end try
                end if
                error originalError number originalNumber
            end try
            my rejectForbidden(axElements)
        end tell
    end tell

    tell application "System Events"
        tell process "TokenUsageApp"
            set visibleElements to entire contents
            set visiblePopover to my findIdentifier(visibleElements, "usage-popover-window")
            if visiblePopover is missing value then
                set tokenItems to menu bar items of menu bar 1 whose description is "Token Usage status"
                if (count tokenItems) is not 1 then error "Token Usage status item was not uniquely identifiable"
                click item 1 of tokenItems
                set visibleElements to entire contents
                set visiblePopover to my requireIdentifier(visibleElements, "usage-popover-window", "usage popover content")
            end if
            set popoverPosition to position of visiblePopover
            set popoverSize to size of visiblePopover
            set captureRegion to (item 1 of popoverPosition as integer) & "," & (item 2 of popoverPosition as integer) & "," & (item 1 of popoverSize as integer) & "," & (item 2 of popoverSize as integer)
        end tell
    end tell
    my logAction(actionLog, "open usage popover")
    do shell script "/usr/sbin/screencapture -x -R" & captureRegion & " " & quoted form of (screenshotsDirectory & "/usage-popover.png")
    my logAction(actionLog, "verified status item, quota resets, profile controls, and scope exclusions")
    tell application "System Events"
        tell process "TokenUsageApp"
            set quitAction to my requireAction(entire contents, "quit", "Quit Token Usage action")
            perform action "AXPress" of quitAction
        end tell
    end tell
    my logAction(actionLog, "requested Quit through native control")
end run

on requireQuota(elements, identifier, name, requireLive)
    set quotaElement to my requireIdentifier(elements, identifier, name & " quota")
    set quotaDescription to my requireDescription(quotaElement, "Reset", name & " quota reset timing")
    ignoring case
        if requireLive and quotaDescription does not contain "% remaining" then
            error name & " quota is unavailable during live-quota QA"
        end if
        if quotaDescription does not contain "% remaining" and quotaDescription does not contain "Unavailable" then
            error name & " quota has no accessible remaining value"
        end if
    end ignoring
end requireQuota

on allProfileQuotaRows(elements)
    set profileRows to {}
    repeat with candidate in elements
        set candidateIdentifier to my identifierOf(candidate)
        if candidateIdentifier starts with "codex-profile-quota-" and candidateIdentifier is not "codex-profile-quota-scroll" then
            set end of profileRows to contents of candidate
        end if
    end repeat
    if (count profileRows) is 0 then error "no profile-specific Codex weekly quotas were exposed to accessibility"
    return profileRows
end allProfileQuotaRows

on requireProfileQuotaRows(profileRows, expectedProfiles, requireLive, actionLog)
    set expectedRows to {}
    set profileIdentifiers to {}
    repeat with expectedProfile in expectedProfiles
        set expectedName to contents of expectedProfile
        set matches to {}
        repeat with candidate in profileRows
            set profileDescription to my attributeText(candidate, "AXDescription")
            ignoring case
                if profileDescription starts with expectedName & ", profile ID " then set end of matches to contents of candidate
            end ignoring
        end repeat
        if (count matches) is not 1 then
            error "profile quota row for " & expectedName & " was not uniquely exposed to accessibility"
        end if
        set profileRow to item 1 of matches
        set rowIdentifier to my identifierOf(profileRow)
        if rowIdentifier is in profileIdentifiers then
            error "profile quota row identifier was reused: " & rowIdentifier
        end if
        set end of profileIdentifiers to rowIdentifier
        set rowText to my requireDescription(profileRow, "Reset", expectedName & " weekly quota reset timing")
        ignoring case
            if requireLive and rowText does not contain "% remaining" then
                error expectedName & " weekly quota is unavailable during live-quota QA"
            end if
            if rowText does not contain "% remaining" and rowText does not contain "Unavailable" then
                error expectedName & " weekly quota has no accessible remaining value"
            end if
        end ignoring
        set end of expectedRows to profileRow
        my logAction(actionLog, "verified profile quota " & rowIdentifier & ": " & rowText)
    end repeat
    return expectedRows
end requireProfileQuotaRows

on requireExactlyOneActiveProfile(profileRows)
    set activeCount to 0
    repeat with profileRow in profileRows
        set rowText to my accessibleText(profileRow)
        ignoring case
            if rowText contains ", Active," then set activeCount to activeCount + 1
        end ignoring
    end repeat
    if activeCount is not 1 then error "expected exactly one Active profile marker, found " & activeCount
end requireExactlyOneActiveProfile

on requireActiveProfileRow(profileRows, expectedProfile)
    repeat with profileRow in profileRows
        set rowText to my accessibleText(profileRow)
        ignoring case
            if rowText contains expectedProfile and rowText contains ", Active," then return
        end ignoring
    end repeat
    error "selected profile did not expose the Active marker: " & expectedProfile
end requireActiveProfileRow

on profileNameFromPicker(profilePicker, expectedProfiles)
    set pickerValue to my attributeText(profilePicker, "AXValue")
    repeat with expectedProfile in expectedProfiles
        if pickerValue is (contents of expectedProfile) then return contents of expectedProfile
    end repeat
    set pickerText to my accessibleText(profilePicker)
    set matches to {}
    repeat with expectedProfile in expectedProfiles
        set expectedName to contents of expectedProfile
        ignoring case
            if pickerText contains expectedName then set end of matches to expectedName
        end ignoring
    end repeat
    if (count matches) is 1 then return item 1 of matches
    error "original active profile was not uniquely identifiable among expected profiles"
end profileNameFromPicker

on selectionTarget(expectedProfiles, originalActiveProfile)
    repeat with expectedProfile in expectedProfiles
        if (contents of expectedProfile) is not originalActiveProfile then return contents of expectedProfile
    end repeat
    return item 1 of expectedProfiles
end selectionTarget

on restoreOriginalProfile(originalActiveProfile, actionLog)
    try
        tell application "System Events"
            if not (exists process "TokenUsageApp") then error "TokenUsageApp exited before restore"
            tell process "TokenUsageApp"
                set profilePicker to my requireIdentifier(entire contents, "codex-profile-picker", "active Codex account")
                set currentProfileText to my accessibleText(profilePicker)
                if currentProfileText does not contain originalActiveProfile then
                    perform action "AXPress" of profilePicker
                    set menuElements to entire contents
                    set originalProfileItem to my requireName(menuElements, originalActiveProfile, "original Codex profile")
                    perform action "AXPress" of originalProfileItem
                    set restoredPicker to my requireIdentifier(entire contents, "codex-profile-picker", "restored Codex account")
                    my requireDescription(restoredPicker, originalActiveProfile, "restored Codex account value")
                end if
                set restoredRows to my allProfileQuotaRows(entire contents)
                my requireExactlyOneActiveProfile(restoredRows)
                my requireActiveProfileRow(restoredRows, originalActiveProfile)
            end tell
        end tell
        my logAction(actionLog, "restored original active profile " & originalActiveProfile)
    on error restoreError
        error "failed to restore original active profile: " & restoreError
    end try
end restoreOriginalProfile

on requireAction(elements, identifier, label)
    set action to my requireIdentifier(elements, identifier, label)
    return action
end requireAction

on requireIdentifier(elements, identifier, label)
    set candidate to my findIdentifier(elements, identifier)
    if candidate is not missing value then return candidate
    error label & " was not exposed to accessibility"
end requireIdentifier

on findIdentifier(elements, identifier)
    repeat with candidate in elements
        try
            tell application "System Events"
                set candidateIdentifier to value of attribute "AXIdentifier" of candidate
            end tell
            if candidateIdentifier is identifier then return contents of candidate
        end try
    end repeat
    return missing value
end findIdentifier

on identifierOf(element)
    try
        tell application "System Events" to return value of attribute "AXIdentifier" of element as text
    end try
    return ""
end identifierOf

on attributeText(element, attributeName)
    try
        tell application "System Events" to return value of attribute attributeName of element as text
    end try
    return "<unavailable>"
end attributeText

on accessibleText(element)
    set candidateDescription to "<unavailable>"
    set candidateName to "<unavailable>"
    set candidateValue to "<unavailable>"
    try
        tell application "System Events" to set candidateDescription to value of attribute "AXDescription" of element as text
    end try
    try
        tell application "System Events" to set candidateName to value of attribute "AXTitle" of element as text
    end try
    try
        tell application "System Events" to set candidateValue to value of attribute "AXValue" of element as text
    end try
    return candidateDescription & " " & candidateName & " " & candidateValue
end accessibleText

on requireDescription(element, expected, label)
    set candidateText to my accessibleText(element)
    ignoring case
        if candidateText contains expected then return candidateText
    end ignoring
    error label & " was not exposed to accessibility (actual: " & candidateText & ")"
end requireDescription

on requireName(elements, expected, label)
    repeat with candidate in elements
        try
            tell application "System Events" to set candidateName to name of candidate
            if (candidateName as text) is expected then return contents of candidate
        end try
    end repeat
    error label & " was not exposed to accessibility"
end requireName

on rejectForbidden(elements)
    set forbiddenTerms to {"statistics", "history", "cost", "token-count"}
    repeat with candidate in elements
        try
            set candidateDescription to description of candidate as text
            ignoring case
                repeat with forbiddenTerm in forbiddenTerms
                    if candidateDescription contains (contents of forbiddenTerm) then
                        error "forbidden scope label exposed: " & (contents of forbiddenTerm)
                    end if
                end repeat
            end ignoring
        end try
    end repeat
end rejectForbidden

on logAction(actionLog, actionText)
    set scriptDirectory to do shell script "/usr/bin/dirname " & quoted form of POSIX path of (path to me)
    do shell script quoted form of (scriptDirectory & "/action-log.sh") & " --log " & quoted form of actionLog & " --action " & quoted form of actionText
end logAction
