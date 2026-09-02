$ErrorActionPreference = "Stop"

function ConvertTo-GlobRegex {
    param([Parameter(Mandatory = $true)][string]$Pattern)

    $builder = [System.Text.StringBuilder]::new()
    for ($index = 0; $index -lt $Pattern.Length; $index++) {
        $character = $Pattern[$index]
        if ($character -eq "*" -and
            $index + 1 -lt $Pattern.Length -and
            $Pattern[$index + 1] -eq "*") {
            [void]$builder.Append(".*")
            $index++
        }
        elseif ($character -eq "*") {
            [void]$builder.Append("[^/]*")
        }
        elseif ($character -eq "?") {
            [void]$builder.Append("[^/]")
        }
        else {
            [void]$builder.Append([Regex]::Escape([string]$character))
        }
    }
    return $builder.ToString()
}

function Get-StringValues {
    param($Value)

    if ($Value -is [string]) {
        $Value
    }
    elseif ($Value -is [System.Collections.IDictionary] -or
        $Value -is [PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            Get-StringValues $property.Value
        }
    }
    elseif ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            Get-StringValues $item
        }
    }
}

function Test-ProtectedReference {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string[]]$GlobRegexes
    )

    $normalized = $Value.Replace("\", "/")
    foreach ($globRegex in $GlobRegexes) {
        $referenceRegex = "(?i)(?<![a-z0-9_.-])$globRegex" +
            "(?=$|[\s`"'=:;|&>)])"
        if ($normalized -match $referenceRegex) {
            return $true
        }
    }
    return $false
}

try {
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
    $payloadText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($payloadText)) {
        throw "The hook payload is empty."
    }

    $payload = $payloadText | ConvertFrom-Json
    if (-not $payload.toolName -or $null -eq $payload.toolArgs) {
        throw "The hook payload must contain toolName and toolArgs."
    }

    $patternsFile = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine(
            $PSScriptRoot,
            "..",
            "protected-files.txt"
        )
    )
    $patterns = @(
        Get-Content -LiteralPath $patternsFile |
            ForEach-Object { $_.Trim().Replace("\", "/") } |
            Where-Object { $_ -and -not $_.StartsWith("#") }
    )
    if ($patterns.Count -eq 0) {
        throw "The protected-files configuration has no patterns."
    }

    $globRegexes = @($patterns | ForEach-Object { ConvertTo-GlobRegex $_ })
    $values = @(Get-StringValues $payload.toolArgs)
    $referencesProtectedFile = $false
    foreach ($value in $values) {
        if (Test-ProtectedReference $value $globRegexes) {
            $referencesProtectedFile = $true
            break
        }
    }

    if (-not $referencesProtectedFile) {
        exit 0
    }

    $toolName = ([string]$payload.toolName).ToLowerInvariant()
    $fileMutationTools = @(
        "apply_patch",
        "create",
        "delete",
        "edit",
        "str_replace_editor",
        "write"
    )
    $shouldDeny = $fileMutationTools -contains $toolName

    if ($toolName -in @("bash", "powershell")) {
        $command = $values -join "`n"
        $mutationPattern = "(?i)(" +
            "\b(add-content|clear-content|copy-item|del|erase|move-item|" +
            "remove-item|rename-item|set-content)\b|" +
            "\b(cp|install|mv|rm|truncate)\b|" +
            "\bgit\s+(checkout|clean|mv|reset|restore|rm)\b|" +
            "\b(perl|sed)\b[^\r\n;&|]*\s-[^\r\n;&|]*i|" +
            "\btee\b|(^|[\s;|&])(echo|printf)\b[^\r\n]*(>>|>)|" +
            "(>>|>))"
        $shouldDeny = $command -match $mutationPattern
    }

    if ($shouldDeny) {
        [ordered]@{
            permissionDecision = "deny"
            permissionDecisionReason = (
                "A política do repositório impede que agentes modifiquem, " +
                "movam ou excluam arquivos correspondentes aos padrões em " +
                ".github/protected-files.txt."
            )
        } | ConvertTo-Json -Compress
    }
}
catch {
    [Console]::Error.WriteLine(
        "Failed to enforce protected-file policy: {0}" -f
        $_.Exception.Message
    )
    exit 1
}
