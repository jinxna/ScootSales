# Real-device leg: runs the Android integration test for assigned-route arrival
# on a running Android emulator against the LOCAL Firebase emulators.
#
#   npm run test:e2e:device      (starts the Firebase emulators, then runs this)
#
# Prerequisites: an Android emulator already booted (adb device online), JDK 21+,
# Flutter. The integration test feeds synthetic GPS positions through a
# test-only Geolocator override, so this is not evidence of a real visit.
#
# Before the test the script checks that Android is ready (boot, device network,
# host emulator ports; boot polls for up to 180 s, the others for up to 60 s) and clears the app data
# of the package that the build installs. It never retries the test itself.
#
# Evidence (git-ignored, in e2e/output/):
#   no -Edition   : device_native_result.json  / device_native.log
#   -Edition <e>  : device_<e>_result.json     / device_<e>.log
#   (a non-default -Test inserts its name: device_<test>_result.json, or
#    device_<test>_<e>_result.json with an edition)
# The result JSON records edition, device (AVD name, screen size), source
# (git HEAD + sha256 of `git diff HEAD -- flutter_mobile_app e2e`) and the
# start and finish time in UTC.
#
# failureStage is one of: preflight, android_boot, android_network,
# fixture_prepare, android_integration_test. (App install is part of
# `flutter test`; without -FlutterVerbose it is not separable, so it has no
# stage of its own and an install failure shows as android_integration_test.)
param(
  [string]$Test = 'integration_test/assigned_route_arrival_acceptance_test.dart',
  [string]$AfterSeedScript = '',
  [string]$AndroidHost = '10.0.2.2',
  [int]$FirestorePort = 18089,
  [int]$AuthPort = 19099,
  # Optional product tier for the app under test; empty keeps the build default (advanced).
  [ValidateSet('', 'basic', 'advanced')][string]$Edition = '',
  # Client the app is built for. Empty keeps the build default (supermarket).
  # Only an explicit value is passed to the build. The device fixtures and the
  # emulator project are pinned to cos40005, so 'hardware' is refused for now.
  [string]$FirebaseTarget = '',
  # Network and fixture checks (each polls for up to this long).
  [int]$ReadyTimeoutSeconds = 60,
  # Android boot check (a cold emulator boot is slower than the network checks).
  [int]$BootTimeoutSeconds = 180,
  [switch]$FlutterVerbose
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# Hard refusal outside the Firebase emulator suite.
foreach ($name in 'FIRESTORE_EMULATOR_HOST', 'FIREBASE_AUTH_EMULATOR_HOST') {
  $value = [Environment]::GetEnvironmentVariable($name)
  if (-not $value) { throw "Refusing to run: $name is not set. Use npm run test:e2e:device." }
  if ($value -notmatch '^(127\.0\.0\.1|localhost|\[::1\]):') { throw "Refusing to run: $name is not local ($value)." }
}

# Application IDs per client: the same map as
# flutter_mobile_app/android/app/build.gradle.kts (clientApps). Keep in sync.
$clientApplicationIds = @{
  'supermarket' = 'my.scootsales.app'
  'hardware'    = 'my.scootsales.app.hardware'
}
$defaultFirebaseTarget = 'supermarket'
$explicitTarget = $FirebaseTarget.Trim().ToLowerInvariant()
$effectiveTarget = if ($explicitTarget) { $explicitTarget } else { $defaultFirebaseTarget }
if (-not $clientApplicationIds.ContainsKey($effectiveTarget)) {
  throw "Unknown FIREBASE_TARGET `"$effectiveTarget`". Use supermarket."
}
if ($effectiveTarget -eq 'hardware') {
  throw 'FIREBASE_TARGET hardware is not supported by the device test yet: its fixtures and the emulator project are pinned to cos40005.'
}
$package = $clientApplicationIds[$effectiveTarget]

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$mobileRoot = Join-Path $repoRoot 'flutter_mobile_app'
$outDir = Join-Path $PSScriptRoot '..\output'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outDir = (Resolve-Path $outDir).Path
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')
$env:FYP_A_ROUTE_ARRIVAL_FIXTURE_BACKUP = Join-Path $outDir "route-arrival-fixture-backup-$runId.json"
$definePath = Join-Path $outDir 'dev_accounts_e2e.json'
$defaultTest = 'integration_test/assigned_route_arrival_acceptance_test.dart'
if ($Test -eq $defaultTest) {
  $baseName = if ($Edition) { "device_$Edition" } else { 'device_native' }
} else {
  $testName = [IO.Path]::GetFileNameWithoutExtension($Test) -replace '[^A-Za-z0-9_-]', '_'
  $baseName = if ($Edition) { "device_${testName}_$Edition" } else { "device_${testName}" }
}
$reportPath = Join-Path $outDir "${baseName}_result.json"
$logPath = Join-Path $outDir "$baseName.log"
$repoRootPrefix = $repoRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$logReportPath = $logPath.Substring($repoRootPrefix.Length).Replace('\', '/')
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$started = [DateTime]::UtcNow
$outcome = 'failed'; $stage = 'preflight'; $message = ''; $trace = $null
$flutterExit = -1
$deviceTimeMs = $null
$device = $null
$avdName = $null
$wmSize = $null

# Run adb against the chosen device. Never throws; returns Exit and Text.
function Invoke-Adb {
  param([string[]]$AdbArgs)
  $saved = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $lines = & $adb -s $device @AdbArgs 2>&1 | ForEach-Object { $_.ToString() }
    $exit = $LASTEXITCODE
  } finally { $ErrorActionPreference = $saved }
  [pscustomobject]@{ Exit = $exit; Text = (($lines) -join "`n").Trim() }
}

# True when something accepts a TCP connection on the host (IPv4 or IPv6 loopback).
function Test-HostPort {
  param([int]$Port)
  foreach ($address in '127.0.0.1', '::1') {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
      $async = $client.BeginConnect($address, $Port, $null, $null)
      if ($async.AsyncWaitHandle.WaitOne(1000) -and $client.Connected) { return $true }
    } catch {
    } finally { $client.Close() }
  }
  return $false
}

# Poll a check every 2 s until it returns $null (ready) or the time is up.
# The check returns a reason string while it is not ready. Returns the last
# reason, or $null when ready.
function Wait-Ready {
  param([scriptblock]$Check, [int]$TimeoutSeconds)
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $reason = & $Check
    if (-not $reason) { return $null }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  return $reason
}

# Fingerprint of the code under test (git HEAD + hash of the working diff).
$sourceHead = $null
$sourceDiffHash = $null
$savedGitErrorActionPreference = $ErrorActionPreference
try {
  # Windows PowerShell 5.1 turns any git stderr line (for example the CRLF
  # warning) into a terminating error under Stop; read stdout only.
  $ErrorActionPreference = 'Continue'
  $headLines = & git -C $repoRoot rev-parse HEAD 2>$null | ForEach-Object { $_.ToString() }
  if ($LASTEXITCODE -eq 0) { $sourceHead = ($headLines -join '').Trim() }
  if (-not $sourceHead) { $sourceHead = $null }
  $diffLines = & git -C $repoRoot diff HEAD -- flutter_mobile_app e2e 2>$null | ForEach-Object { $_.ToString() }
  if ($LASTEXITCODE -eq 0) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
      $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($diffLines -join "`n"))
    } finally { $sha.Dispose() }
    $sourceDiffHash = (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
  }
} catch {
} finally { $ErrorActionPreference = $savedGitErrorActionPreference }

try {
  if (-not (Test-Path -LiteralPath $adb)) { throw 'adb.exe not found in the Android SDK.' }
  $devices = (& $adb devices) -join "`n"
  if ($devices -notmatch '(emulator-\d+)\s+device') { throw 'No Android emulator is online (adb devices).' }
  $device = $Matches[1]

  # Boot: sys.boot_completed is 1 and the package manager answers.
  $stage = 'android_boot'
  $bootReason = Wait-Ready -TimeoutSeconds $BootTimeoutSeconds -Check {
    $boot = Invoke-Adb @('shell', 'getprop', 'sys.boot_completed')
    if ($boot.Exit -ne 0 -or ($boot.Text -replace "`r", '').Trim() -ne '1') {
      return 'sys.boot_completed is not 1'
    }
    $pm = Invoke-Adb @('shell', 'pm', 'path', 'android')
    if ($pm.Exit -ne 0 -or $pm.Text -notmatch 'package:') {
      return 'the package manager (pm path android) does not answer'
    }
    return $null
  }
  if ($bootReason) { throw "Android is not booted after ${BootTimeoutSeconds}s: $bootReason." }

  # Device facts for the result file (best effort).
  $avd = Invoke-Adb @('shell', 'getprop', 'ro.boot.qemu.avd_name')
  if ($avd.Exit -eq 0 -and $avd.Text.Trim()) { $avdName = $avd.Text.Trim() }
  $wm = Invoke-Adb @('shell', 'wm', 'size')
  if ($wm.Exit -eq 0 -and $wm.Text -match '(\d+x\d+)') { $wmSize = $Matches[1] }

  # Network: the device can reach the host, and the emulators listen on the host.
  $stage = 'android_network'
  Invoke-Adb @('shell', 'cmd', 'connectivity', 'airplane-mode', 'disable') | Out-Null
  Invoke-Adb @('shell', 'svc', 'wifi', 'enable') | Out-Null
  Invoke-Adb @('shell', 'svc', 'data', 'enable') | Out-Null
  $networkReason = Wait-Ready -TimeoutSeconds $ReadyTimeoutSeconds -Check {
    if (-not (Test-HostPort $FirestorePort)) { return "the Firestore emulator is not listening on host port $FirestorePort" }
    if (-not (Test-HostPort $AuthPort)) { return "the Auth emulator is not listening on host port $AuthPort" }
    $ping = Invoke-Adb @('shell', 'ping', '-c', '1', '-W', '2', $AndroidHost)
    if ($ping.Exit -ne 0 -or $ping.Text -notmatch '[1-9]\d* (packets )?received|bytes from') {
      return "the Android emulator cannot reach $AndroidHost"
    }
    return $null
  }
  if ($networkReason) { throw "Android network is not ready after ${ReadyTimeoutSeconds}s: $networkReason." }

  # Clear the app data of the package this build installs. A package that is
  # not installed is fine; any other failure stops the run.
  $stage = 'preflight'
  $installedCheck = Invoke-Adb @('shell', 'pm', 'path', $package)
  $isInstalled = ($installedCheck.Text -match 'package:')
  if ($isInstalled) {
    Invoke-Adb @('shell', 'am', 'force-stop', $package) | Out-Null
    $clear = Invoke-Adb @('shell', 'pm', 'clear', $package)
    if ($clear.Text -match 'Unknown package|not installed') {
      $isInstalled = $false
    } elseif ($clear.Exit -ne 0 -or $clear.Text -notmatch 'Success') {
      throw "pm clear $package failed (exit $($clear.Exit)): $($clear.Text)"
    }
  }
  if ($isInstalled) {
    Invoke-Adb @('shell', 'pm', 'grant', $package, 'android.permission.ACCESS_FINE_LOCATION') | Out-Null
    Invoke-Adb @('shell', 'pm', 'grant', $package, 'android.permission.ACCESS_COARSE_LOCATION') | Out-Null
  }

  $stage = 'fixture_prepare'
  & node (Join-Path $PSScriptRoot 'seed.cjs') | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'seed failed' }
  if (-not [string]::IsNullOrWhiteSpace($AfterSeedScript)) {
    $afterSeedPath = Join-Path $repoRoot $AfterSeedScript
    $resolvedAfterSeedPath = (Resolve-Path -LiteralPath $afterSeedPath).Path
    $e2eRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $e2eRootPrefix = $e2eRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedAfterSeedPath.StartsWith($e2eRootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($resolvedAfterSeedPath) -ne '.cjs' -or
        (Get-Item -LiteralPath $resolvedAfterSeedPath).PSIsContainer) {
      throw 'The after-seed script must be a .cjs file inside e2e/.'
    }
    & node $resolvedAfterSeedPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'after-seed fixture script failed' }
  }
  & node (Join-Path $PSScriptRoot 'arrival_fixture.cjs') prepare | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'arrival fixture failed' }

  $stage = 'android_integration_test'
  Push-Location $mobileRoot
  try {
    $t0 = Get-Date
    $flutterArgs = @(
      'test', '--no-pub', $Test, '-d', $device,
      "--dart-define-from-file=$definePath",
      '--dart-define=USE_FIREBASE_EMULATOR=true',
      "--dart-define=FIREBASE_EMULATOR_HOST=$AndroidHost",
      "--dart-define=FIRESTORE_EMULATOR_PORT=$FirestorePort",
      "--dart-define=FIREBASE_AUTH_EMULATOR_PORT=$AuthPort"
    )
    if ($Edition) { $flutterArgs += "--dart-define=EDITION=$Edition" }
    if ($explicitTarget) { $flutterArgs += "--dart-define=FIREBASE_TARGET=$explicitTarget" }
    if ($FlutterVerbose) { $flutterArgs += '--verbose' }
    $savedErrorActionPreference = $ErrorActionPreference
    try {
      # Flutter writes progress and test diagnostics to stderr. Keep those
      # records in the combined log instead of letting Stop abort the pipeline.
      $ErrorActionPreference = 'Continue'
      $output = & flutter @flutterArgs 2>&1 | Tee-Object -FilePath $logPath | ForEach-Object {
        $line = $_.ToString()
        if ($FlutterVerbose) {
          if ($line -match 'Running Gradle task') {
            Write-Host 'flutter_stage=build'
          } elseif ($line -match 'Installing .*app-debug\.apk') {
            Write-Host 'flutter_stage=install'
          } elseif ($line -match 'Waiting for VM Service port') {
            Write-Host 'flutter_stage=waiting_for_vm_service'
          } elseif ($line -match 'VM Service URL on device') {
            Write-Host 'flutter_stage=vm_service_ready'
          } elseif ($line -match 'ROUTE_ARRIVAL_STAGE (?<stage>[A-Za-z0-9_-]+)') {
            Write-Host "flutter_test_stage=$($Matches.stage)"
          } elseif ($line -match 'ROUTE_ARRIVAL_AUTH_DIAGNOSTIC|PROFILE_(AUTH|READ)_DIAGNOSTIC') {
            Write-Host ($line -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '<email>')
          } elseif ($line -match 'EXCEPTION CAUGHT|TestFailure|StateError|Some tests failed|All tests passed|Test failed|Test passed') {
            $safeLine = $line `
              -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '<email>' `
              -replace 'E2E-Local-Only-\S+', '<test-password>' `
              -replace '(?i)(salesmanUid|userUid|actorUid|uid)[:= ]+\w+', '$1=<redacted>' `
              -replace 'http://127\.0\.0\.1:\d+/[A-Za-z0-9_-]+/', 'http://127.0.0.1:<port>/<token>/' `
              -replace '(?<!\d)-?\d{1,2}\.\d{4,}\s*,\s*-?\d{1,3}\.\d{4,}(?!\d)', '<coordinates>'
            Write-Host $safeLine
          }
        }
        $line
      }
      $flutterExit = $LASTEXITCODE
      $deviceTimeMs = [int]((Get-Date) - $t0).TotalMilliseconds
    } finally { $ErrorActionPreference = $savedErrorActionPreference }
  } finally { Pop-Location }
  if ($flutterExit -ne 0) { throw "flutter test failed (exit $flutterExit); see $logPath" }
  $line = $output | Where-Object { $_.Contains('ROUTE_ARRIVAL_TRACE ') } | Select-Object -Last 1
  if ($line) { $trace = $line.Substring($line.IndexOf('ROUTE_ARRIVAL_TRACE ') + 20) | ConvertFrom-Json }
  $outcome = 'passed'; $stage = ''
} catch {
  $message = $_.Exception.Message
  Write-Output "device_arrival_failed at ${stage}: $message"
} finally {
  & node (Join-Path $PSScriptRoot 'arrival_fixture.cjs') cleanup | Out-Null
}

[ordered]@{
  schemaVersion = 2
  startedAtUtc = $started.ToString('o')
  finishedAtUtc = [DateTime]::UtcNow.ToString('o')
  outcome = $outcome
  failureStage = $stage
  failureMessage = $message
  test = $Test
  edition = $(if ($Edition) { $Edition } else { $null })
  firebaseTarget = $effectiveTarget
  package = $package
  device = [ordered]@{ avdName = $avdName; wmSize = $wmSize }
  source = [ordered]@{ head = $sourceHead; diffHash = $sourceDiffHash }
  scope = 'Android emulator + local Firebase emulators (project cos40005); synthetic GPS via test-only override'
  timingNote = 'EMULATOR timing; not a production measurement.'
  flutterTestWallMs = $deviceTimeMs
  logFile = $logReportPath
  trace = $trace
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding utf8

Write-Output "device_arrival=$outcome; report=$reportPath"
if ($outcome -ne 'passed') { exit 1 }
