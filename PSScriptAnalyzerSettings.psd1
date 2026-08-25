@{
    Severity = @('Error', 'Warning')

    # Every exclusion below is a deliberate call, not a snooze button. If a rule ever
    # catches something real here, delete its entry rather than working around it.
    ExcludeRules = @(
        # These scripts talk to a person, not to a pipeline. Write-Host is the correct
        # cmdlet for that: the output is a progress report, never data to capture.
        'PSAvoidUsingWriteHost'

        # starship and zoxide ship their integration as a string of PowerShell to evaluate.
        # Invoke-Expression is the documented and only supported way to load it.
        'PSAvoidUsingInvokeExpression'

        # Private script functions, never exported as cmdlets. Install-Packages installs
        # packages; renaming it to Install-Package would read as "install one package".
        'PSUseSingularNouns'

        # False positives: -GitUserName / -GitUserEmail are consumed inside Install-GitConfig
        # through the script scope, and native argument completers must declare the full
        # parameter set even when a handler only reads part of it.
        'PSReviewUnusedParameter'

        # Update-SessionPath rewrites $env:Path for this process only, and Set-JsonProperty
        # mutates an in-memory object. Neither touches durable state, so -WhatIf on them
        # would be noise; the callers that do write to disk support it.
        'PSUseShouldProcessForStateChangingFunctions'

        # PowerShell 7 reads UTF-8 without a BOM by default, and a BOM would break the git
        # config fragment. install.ps1, the one file that must also run under Windows
        # PowerShell 5.1, is kept pure ASCII instead so the question never arises.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
