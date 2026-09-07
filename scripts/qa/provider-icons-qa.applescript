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

on run argv
    if (count argv) is not 1 then error "usage: provider-icons-qa.applescript screenshot-path"
    set screenshotPath to item 1 of argv

    tell application "System Events"
        if not (exists process "TokenUsageApp") then error "TokenUsageApp is not running"
        tell process "TokenUsageApp"
            set controls to entire contents
            set popoverContent to my findIdentifier(controls, "usage-popover-window")
            if popoverContent is missing value then
                set tokenItems to menu bar items of menu bar 1 whose description is "Token Usage status"
                if (count tokenItems) is not 1 then error "Token Usage status item was not uniquely identifiable"
                click item 1 of tokenItems
                set controls to entire contents
                set popoverContent to my findIdentifier(controls, "usage-popover-window")
            end if
            if popoverContent is missing value then error "usage popover did not open"

            set anthropicIcon to my findIdentifier(controls, "provider-anthropic-icon")
            if anthropicIcon is missing value then error "missing provider icon: Anthropic"

            set openAIIcon to my findIdentifier(controls, "provider-openai-icon")
            if openAIIcon is missing value then error "missing provider icon: OpenAI"

            set popoverPosition to position of popoverContent
            set popoverSize to size of popoverContent
            set captureRegion to (item 1 of popoverPosition as integer) & "," & (item 2 of popoverPosition as integer) & "," & (item 1 of popoverSize as integer) & "," & (item 2 of popoverSize as integer)
        end tell
    end tell

    do shell script "/usr/sbin/screencapture -x -R" & captureRegion & " " & quoted form of screenshotPath
    return "verified Anthropic and OpenAI provider image identifiers" & linefeed & "captured provider popover " & captureRegion
end run
