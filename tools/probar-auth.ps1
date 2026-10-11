param([int]$Port = 7778)
$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('gm-venta-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot,(Join-Path $testRoot 'gamemodes'),(Join-Path $testRoot 'scriptfiles'),(Join-Path $testRoot 'models') | Out-Null
Copy-Item -LiteralPath (Join-Path $serverRoot 'components'),(Join-Path $serverRoot 'plugins') -Destination $testRoot -Recurse
Copy-Item -LiteralPath (Join-Path $serverRoot 'omp-server.exe') -Destination $testRoot
Copy-Item -LiteralPath (Join-Path $serverRoot 'scriptfiles\cef') -Destination (Join-Path $testRoot 'scriptfiles') -Recurse
$testConfig = @{
    pawn = @{ main_scripts = @('auth_security 1'); side_scripts = @(); legacy_plugins = @('samp_bcrypt') }
    name = 'Pruebas de autenticacion'; announce = $false; max_players = 10
    rcon = @{ enable = $false }
    logging = @{ file = 'test.log'; enable = $true; log_sqlite = $false; log_sqlite_queries = $false }
    network = @{ port = $Port; bind = '127.0.0.1' }
    cef = @{ debug = $false; resources_loader_mode = 'none'; master_resource_key = [guid]::NewGuid().ToString('N') }
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $testRoot 'config.json'), $testConfig)
$compilerArgs = @(
    ('"' + (Join-Path $serverRoot 'tests\auth_security.pwn') + '"'),
    ('-o"' + (Join-Path $testRoot 'gamemodes\auth_security.amx') + '"'),
    ('-i"' + (Join-Path $serverRoot 'qawno\include') + '"'), '-d2', '-E', '-;+', '-(+'
)
$compiler = Start-Process -FilePath (Join-Path $serverRoot 'tools\pawn-3.10.10\pawncc.exe') -ArgumentList $compilerArgs -WorkingDirectory $serverRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $testRoot 'compile.stdout') -RedirectStandardError (Join-Path $testRoot 'compile.stderr')
if ($compiler.ExitCode -ne 0) {
    Get-Content -LiteralPath (Join-Path $testRoot 'compile.stdout'),(Join-Path $testRoot 'compile.stderr')
    throw "No se pudieron compilar las pruebas. Archivos: $testRoot"
}
$processInfo = [System.Diagnostics.ProcessStartInfo]::new()
$processInfo.FileName = Join-Path $testRoot 'omp-server.exe'
$processInfo.WorkingDirectory = $testRoot
$processInfo.UseShellExecute = $false
$processInfo.CreateNoWindow = $true
$processInfo.WindowStyle = 'Hidden'
$processInfo.RedirectStandardInput = $true
$processInfo.RedirectStandardOutput = $true
$processInfo.RedirectStandardError = $true
$server = [System.Diagnostics.Process]::Start($processInfo)
$stdout = $server.StandardOutput.ReadToEndAsync()
$stderr = $server.StandardError.ReadToEndAsync()
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$logPath = Join-Path $testRoot 'test.log'
try {
    while (!$server.HasExited -and $watch.Elapsed.TotalSeconds -lt 75) {
        if ((Test-Path -LiteralPath $logPath) -and (Select-String -LiteralPath $logPath -Pattern '\[TEST\] FIN:' -Quiet)) { break }
        Start-Sleep -Milliseconds 100
    }
    # El proceso pertenece exclusivamente a estas pruebas con base temporal.
    if (!$server.HasExited) {
        $server.StandardInput.WriteLine('exit')
        $server.StandardInput.Flush()
        if (!$server.WaitForExit(5000)) { $server.Kill(); $server.WaitForExit() }
    }
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'server.stdout'), $stdout.GetAwaiter().GetResult())
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'server.stderr'), $stderr.GetAwaiter().GetResult())
    $testLog = Get-Content -LiteralPath $logPath -Raw
    $summary = [regex]::Match($testLog, '\[TEST\] FIN: (\d+) fallos, (\d+) comprobaciones')
    if (!$summary.Success -or $summary.Groups[1].Value -ne '0' -or $testLog -match '\[TEST\] FAIL:|Runtime error|\[Error\]') {
        throw "Las pruebas fallaron o no terminaron. Revisa $testRoot"
    }
    Write-Output $summary.Value
    Write-Output "Resultados y base temporal: $testRoot"
} finally {
    if (!$server.HasExited) { $server.Kill(); $server.WaitForExit() }
    $server.Dispose()
}
