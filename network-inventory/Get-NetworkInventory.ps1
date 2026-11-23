<#
.SYNOPSIS
Inventories the devices on an IPv4 subnet: address, host name, MAC address, vendor and open ports.

.DESCRIPTION
Pings every address in the subnet at once. For each device that answers, it looks up the host name in
DNS, the MAC address in the Windows neighbor (ARP) table and the vendor that owns that MAC address, and
checks a short list of TCP ports. Devices that block ping but answered ARP are listed too.

MAC addresses and vendors are only visible for devices on the same network segment as this computer:
behind a router, Windows only sees the router. Vendors come from the IEEE list of MAC address blocks,
downloaded once with -UpdateVendorList and kept next to the script. MAC addresses are never sent anywhere.

The script only reads: it changes nothing on the network or on the devices. Scan only networks you own
or are allowed to scan.

.PARAMETER Subnet
The IPv4 subnet in CIDR notation, from /22 (1,022 addresses) to /32. Example: 192.0.2.0/24.

.PARAMETER Port
TCP ports to check on each device. Default: 22, 23, 53, 80, 443, 445, 3389, 5985, 8080 and 9100.

.PARAMETER SkipPortScan
Do not check ports; only find the devices.

.PARAMETER Format
Report format: Csv, Html or Both. Default: Csv.

.PARAMETER OutputFolder
Folder for the report. Default: the current folder. The file is named
network-inventory-<subnet>-<date>-<time>.csv or .html.

.PARAMETER PingTimeoutMs
How long to wait for each ping reply, in milliseconds. Default: 1000.

.PARAMETER PortTimeoutMs
How long to wait for each port to accept a connection, in milliseconds. Default: 500.

.PARAMETER UpdateVendorList
Download the IEEE list of MAC address blocks (about 5 MB) to -VendorListPath before scanning. Needed once;
run it again now and then to pick up new vendors.

.PARAMETER VendorListPath
Where the IEEE list is kept. Default: oui.csv next to the script.

.EXAMPLE
.\Get-NetworkInventory.ps1 -Subnet 192.0.2.0/24 -UpdateVendorList

.EXAMPLE
.\Get-NetworkInventory.ps1 -Subnet 192.0.2.0/24 -Format Html

.EXAMPLE
.\Get-NetworkInventory.ps1 -Subnet 10.0.20.0/24 -Port 22, 443 -Format Both -OutputFolder C:\Reports
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$')]
    [string]$Subnet,

    [ValidateRange(1, 65535)]
    [int[]]$Port = @(22, 23, 53, 80, 443, 445, 3389, 5985, 8080, 9100),

    [switch]$SkipPortScan,

    [ValidateSet('Csv', 'Html', 'Both')]
    [string]$Format = 'Csv',

    [string]$OutputFolder = (Get-Location).Path,

    [ValidateRange(100, 10000)]
    [int]$PingTimeoutMs = 1000,

    [ValidateRange(100, 10000)]
    [int]$PortTimeoutMs = 500,

    [switch]$UpdateVendorList,

    [string]$VendorListPath = (Join-Path $PSScriptRoot 'oui.csv')
)

$vendorListUrl = 'https://standards-oui.ieee.org/oui/oui.csv'
$serviceNames = @{
    22 = 'SSH'; 23 = 'Telnet'; 53 = 'DNS'; 80 = 'HTTP'; 135 = 'RPC'; 139 = 'NetBIOS'; 443 = 'HTTPS'; 445 = 'SMB'
    3389 = 'RDP'; 5985 = 'WinRM'; 8080 = 'HTTP (alt)'; 9100 = 'Printing (raw)'
}

function ConvertTo-IPNumber {
    param([System.Net.IPAddress]$Address)
    $bytes = $Address.GetAddressBytes()
    [Array]::Reverse($bytes)
    return [uint64][BitConverter]::ToUInt32($bytes, 0)
}

function ConvertTo-IPString {
    param([uint64]$Number)
    $bytes = [BitConverter]::GetBytes([uint32]$Number)
    [Array]::Reverse($bytes)
    return (New-Object System.Net.IPAddress (, $bytes)).ToString()
}

function ConvertTo-MacAddress {
    # Windows writes MAC addresses with dashes, colons or nothing, depending on the cmdlet; use one format.
    param([string]$Text)
    $hex = ($Text -replace '[^0-9A-Fa-f]').ToUpperInvariant()
    if ($hex.Length -ne 12 -or $hex -eq '000000000000' -or $hex -eq 'FFFFFFFFFFFF') { return '' }
    return ($hex -split '(..)' -ne '') -join '-'
}

function Wait-Task {
    # Waits for the tasks without throwing when some fail: a refused connection or a failed ping is an
    # answer too. Tasks still running at the deadline are left behind and read as no answer.
    param([object[]]$Task, [int]$TimeoutMs)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while (@($Task | Where-Object { -not $_.IsCompleted }).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
}

function Get-VendorName {
    param([string]$MacAddress, [hashtable]$VendorList)
    if (-not $MacAddress) { return '' }
    # The second-lowest bit of the first byte marks a locally administered address: phones and laptops
    # use those as private (randomized) addresses, so no vendor owns them.
    if ([Convert]::ToInt32($MacAddress.Substring(0, 2), 16) -band 2) { return 'Private (randomized) MAC' }
    if (-not $VendorList) { return '' }
    $vendor = $VendorList[$MacAddress.Substring(0, 8).Replace('-', '')]
    if ($vendor) { return $vendor }
    return 'Unknown'
}

function ConvertTo-HtmlReport {
    param([object[]]$Device, [string]$Title, [string]$Subtitle, [int[]]$CheckedPort)
    $encode = { param($Text) [System.Net.WebUtility]::HtmlEncode("$Text") }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<!DOCTYPE html>')
    $null = $sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    $null = $sb.AppendLine("<title>$(& $encode $Title)</title>")
    $null = $sb.AppendLine(@'
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2328; }
h1 { font-size: 22px; margin-bottom: 4px; }
h2 { font-size: 17px; margin-top: 28px; }
.meta { color: #59636e; margin-top: 0; }
.cards { display: flex; gap: 12px; flex-wrap: wrap; }
.card { border: 1px solid #d1d9e0; border-radius: 6px; padding: 10px 16px; min-width: 140px; }
.card b { display: block; font-size: 24px; }
table { border-collapse: collapse; font-size: 14px; }
th, td { border: 1px solid #d1d9e0; padding: 5px 10px; text-align: left; vertical-align: top; }
th { background: #f6f8fa; }
tr:nth-child(even) td { background: #fbfcfd; }
.none { color: #8c959f; }
</style></head><body>
'@)
    $null = $sb.AppendLine("<h1>$(& $encode $Title)</h1>")
    $null = $sb.AppendLine("<p class=""meta"">$(& $encode $Subtitle)</p>")

    $withPorts = @($Device | Where-Object { $_.OpenPorts }).Count
    $randomized = @($Device | Where-Object { $_.Vendor -eq 'Private (randomized) MAC' }).Count
    $arpOnly = @($Device | Where-Object { $_.Responded -eq 'ARP only' }).Count
    $null = $sb.AppendLine('<div class="cards">')
    foreach ($card in @(
            @('Devices', $Device.Count), @('With open ports', $withPorts),
            @('Randomized MACs', $randomized), @('Answered ARP only', $arpOnly))) {
        $null = $sb.AppendLine("<div class=""card""><b>$($card[1])</b>$($card[0])</div>")
    }
    $null = $sb.AppendLine('</div>')

    $vendors = @($Device | Where-Object { $_.Vendor } | Group-Object Vendor | Sort-Object @{ Expression = 'Count'; Descending = $true }, Name)
    if ($vendors.Count -gt 0) {
        $null = $sb.AppendLine('<h2>Devices per vendor</h2><table><tr><th>Vendor</th><th>Devices</th></tr>')
        foreach ($group in $vendors) { $null = $sb.AppendLine("<tr><td>$(& $encode $group.Name)</td><td>$($group.Count)</td></tr>") }
        $null = $sb.AppendLine('</table>')
    }

    if ($CheckedPort.Count -gt 0) {
        $null = $sb.AppendLine('<h2>Open ports</h2><table><tr><th>Port</th><th>Service</th><th>Devices</th></tr>')
        foreach ($p in $CheckedPort) {
            $hosts = @($Device | Where-Object { ($_.OpenPorts -split ', ') -contains "$p" } | ForEach-Object { $_.IPAddress })
            $list = if ($hosts.Count -gt 0) { & $encode ($hosts -join ', ') } else { '<span class="none">none</span>' }
            $null = $sb.AppendLine("<tr><td>$p</td><td>$(& $encode $serviceNames[$p])</td><td>$list</td></tr>")
        }
        $null = $sb.AppendLine('</table>')
    }

    $null = $sb.AppendLine('<h2>Devices</h2><table><tr><th>IP address</th><th>Host name</th><th>MAC address</th><th>Vendor</th><th>Open ports</th><th>Responded</th><th>Note</th></tr>')
    foreach ($d in $Device) {
        $cells = foreach ($value in $d.IPAddress, $d.HostName, $d.MacAddress, $d.Vendor, $d.OpenPorts, $d.Responded, $d.Note) { "<td>$(& $encode $value)</td>" }
        $null = $sb.AppendLine("<tr>$(-join $cells)</tr>")
    }
    $null = $sb.AppendLine('</table></body></html>')
    return $sb.ToString()
}

# The subnet and the addresses in it.
$parts = $Subnet -split '/'
$prefix = [int]$parts[1]
$baseAddress = $null
if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$baseAddress) -or $prefix -gt 32) {
    Write-Error "Not a valid IPv4 subnet: $Subnet"
    exit 1
}
if ($prefix -lt 22) {
    Write-Error "The subnet is too large: /$prefix. Use /22 (1,022 addresses) or smaller, and scan larger ranges in parts."
    exit 1
}
$size = [uint64]1 -shl (32 - $prefix)
$network = (ConvertTo-IPNumber -Address $baseAddress)
$network = $network - ($network % $size)
if ($prefix -ge 31) {
    $first = $network
    $last = $network + $size - 1
} else {
    # Skip the network and broadcast addresses.
    $first = $network + 1
    $last = $network + $size - 2
}
$addresses = @(for ($n = $first; $n -le $last; $n++) { ConvertTo-IPString -Number $n })
$cidr = "$(ConvertTo-IPString -Number $network)/$prefix"

# .NET file methods resolve relative paths from the process folder, not from the PowerShell location.
$OutputFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFolder)
# Not Test-Path: in Windows PowerShell 5.1 it stops with an error on a share that cannot be reached.
if (-not [System.IO.Directory]::Exists($OutputFolder)) {
    Write-Error "The output folder does not exist: $OutputFolder"
    exit 1
}

# Vendor list.
if ($UpdateVendorList) {
    Write-Host "Downloading the IEEE vendor list to $VendorListPath..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # The IEEE server refuses the default user agent of Windows PowerShell 5.1 (HTTP 418).
        Invoke-WebRequest -Uri $vendorListUrl -OutFile $VendorListPath -UseBasicParsing -UserAgent 'Get-NetworkInventory.ps1' -ErrorAction Stop
    } catch {
        Write-Error "Could not download the vendor list from ${vendorListUrl}: $($_.Exception.Message)"
        exit 1
    }
}
$vendorList = $null
if (Test-Path -LiteralPath $VendorListPath) {
    $vendorList = @{}
    foreach ($row in (Import-Csv -LiteralPath $VendorListPath)) { $vendorList[$row.Assignment] = $row.'Organization Name'.Trim() }
} else {
    Write-Warning "No vendor list at $VendorListPath, so the Vendor column stays empty. Run once with -UpdateVendorList to download it."
}

# This computer's own addresses: it answers its own ping, but it is not in its neighbor table.
$localAddresses = @{}
foreach ($ip in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
    $adapter = Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex -ErrorAction SilentlyContinue
    $localAddresses[$ip.IPAddress] = if ($adapter) { ConvertTo-MacAddress -Text $adapter.MacAddress } else { '' }
}
$onSegment = @($addresses | Where-Object { $localAddresses.ContainsKey($_) }).Count -gt 0

# 1. Ping sweep, in batches so the number of open requests stays reasonable.
Write-Host "Scanning $($addresses.Count) address(es) in $cidr..."
$answeredPing = @{}
for ($i = 0; $i -lt $addresses.Count; $i += 256) {
    Write-Progress -Activity "Scanning $cidr" -Status 'Ping' -PercentComplete ($i * 100 / $addresses.Count)
    $batch = @($addresses[$i..([Math]::Min($i + 255, $addresses.Count - 1))])
    $pings = @(foreach ($address in $batch) {
            $ping = New-Object System.Net.NetworkInformation.Ping
            [pscustomobject]@{ Address = $address; Ping = $ping; Task = $ping.SendPingAsync($address, $PingTimeoutMs) }
        })
    Wait-Task -Task $pings.Task -TimeoutMs ($PingTimeoutMs + 2000)
    foreach ($p in $pings) {
        if ($p.Task.Status -eq 'RanToCompletion' -and $p.Task.Result.Status -eq 'Success') { $answeredPing[$p.Address] = $true }
        $p.Ping.Dispose()
    }
}

# 2. MAC addresses. Pinging made Windows ask for every address over ARP, so devices that block ping but
# are on this segment are in the neighbor table now too.
$macByAddress = @{}
foreach ($entry in @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
    if ("$($entry.State)" -in 'Unreachable', 'Incomplete') { continue }
    $mac = ConvertTo-MacAddress -Text $entry.LinkLayerAddress
    if ($mac) { $macByAddress[$entry.IPAddress] = $mac }
}
foreach ($address in $localAddresses.Keys) { if ($localAddresses[$address]) { $macByAddress[$address] = $localAddresses[$address] } }

$found = @($addresses | Where-Object { $answeredPing.ContainsKey($_) -or ($onSegment -and $macByAddress.ContainsKey($_)) })

# 3. Host names, all looked up at once.
Write-Progress -Activity "Scanning $cidr" -Status 'Host names' -PercentComplete 50
$lookups = @(foreach ($address in $found) {
        [pscustomobject]@{ Address = $address; Task = [System.Net.Dns]::GetHostEntryAsync($address) }
    })
if ($lookups.Count -gt 0) { Wait-Task -Task $lookups.Task -TimeoutMs 5000 }
$nameByAddress = @{}
foreach ($l in $lookups) {
    if ($l.Task.Status -eq 'RanToCompletion' -and $l.Task.Result.HostName -ne $l.Address) { $nameByAddress[$l.Address] = $l.Task.Result.HostName }
}

# 4. Open ports, a few devices at a time.
$portsByAddress = @{}
if (-not $SkipPortScan) {
    $Port = @($Port | Sort-Object -Unique)
    for ($i = 0; $i -lt $found.Count; $i += 25) {
        Write-Progress -Activity "Scanning $cidr" -Status 'Ports' -PercentComplete (60 + $i * 40 / $found.Count)
        $batch = @($found[$i..([Math]::Min($i + 24, $found.Count - 1))])
        $checks = @(foreach ($address in $batch) {
                foreach ($p in $Port) {
                    $client = New-Object System.Net.Sockets.TcpClient
                    [pscustomobject]@{ Address = $address; Port = $p; Client = $client; Task = $client.ConnectAsync($address, $p) }
                }
            })
        Wait-Task -Task $checks.Task -TimeoutMs $PortTimeoutMs
        foreach ($c in $checks) {
            if ($c.Task.Status -eq 'RanToCompletion' -and $c.Client.Connected) {
                if (-not $portsByAddress.ContainsKey($c.Address)) { $portsByAddress[$c.Address] = New-Object System.Collections.Generic.List[int] }
                $portsByAddress[$c.Address].Add($c.Port)
            }
            $c.Client.Dispose()
        }
    }
}
Write-Progress -Activity "Scanning $cidr" -Completed

# 5. One row per device, in address order. A MAC address seen on more than one address is one device
# with several addresses (or an address conflict), so those rows point at each other.
$addressesByMac = @{}
if ($onSegment) {
    foreach ($address in $found) {
        $mac = "$($macByAddress[$address])"
        if (-not $mac) { continue }
        if (-not $addressesByMac.ContainsKey($mac)) { $addressesByMac[$mac] = New-Object System.Collections.Generic.List[string] }
        $addressesByMac[$mac].Add($address)
    }
}
$devices = @(foreach ($address in $found) {
        $mac = if ($onSegment) { "$($macByAddress[$address])" } else { '' }
        $name = "$($nameByAddress[$address])"
        $notes = New-Object System.Collections.Generic.List[string]
        if ($localAddresses.ContainsKey($address)) {
            $notes.Add('This computer')
            if (-not $name) { $name = $env:COMPUTERNAME }
        }
        if ($mac -and $addressesByMac[$mac].Count -gt 1) {
            $notes.Add("Same MAC as $(@($addressesByMac[$mac] | Where-Object { $_ -ne $address }) -join ', ')")
        }
        $note = $notes -join '; '
        [pscustomobject]@{
            IPAddress  = $address
            HostName   = $name
            MacAddress = $mac
            Vendor     = Get-VendorName -MacAddress $mac -VendorList $vendorList
            OpenPorts  = if ($portsByAddress.ContainsKey($address)) { ($portsByAddress[$address] -join ', ') } else { '' }
            Responded  = if ($answeredPing.ContainsKey($address)) { 'Ping' } else { 'ARP only' }
            Note       = $note
        }
    })

$stamp = Get-Date
$baseName = 'network-inventory-{0}-{1}' -f ($cidr -replace '[./]', '-'), $stamp.ToString('yyyyMMdd-HHmmss')
$written = @()
if ($Format -in 'Csv', 'Both') {
    $csvPath = Join-Path $OutputFolder "$baseName.csv"
    # Windows PowerShell 5.1 writes a "#TYPE" line unless told not to. PowerShell 7 never writes it
    # and warns that the switch is obsolete.
    $csvOptions = @{ LiteralPath = $csvPath; Encoding = 'UTF8' }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $csvOptions.NoTypeInformation = $true }
    $devices | Export-Csv @csvOptions
    $written += $csvPath
}
if ($Format -in 'Html', 'Both') {
    $htmlPath = Join-Path $OutputFolder "$baseName.html"
    $segmentNote = if ($onSegment) { '' } else { ' This computer is not on this subnet, so MAC addresses and vendors are not visible.' }
    $portNote = if ($SkipPortScan) { 'Ports not checked.' } else { "TCP ports checked: $($Port -join ', ')." }
    $subtitle = "Scanned from $env:COMPUTERNAME on $($stamp.ToString('yyyy-MM-dd HH:mm')). $portNote$segmentNote"
    $checkedPorts = if ($SkipPortScan) { @() } else { $Port }
    $html = ConvertTo-HtmlReport -Device $devices -Title "Network inventory: $cidr" -Subtitle $subtitle -CheckedPort $checkedPorts
    [System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding $false))
    $written += $htmlPath
}

if (-not $onSegment) { Write-Warning 'This computer is not on this subnet: MAC addresses and vendors are not visible from here.' }
Write-Host "$cidr`: $($devices.Count) device(s) found, $(@($devices | Where-Object { $_.OpenPorts }).Count) with open ports."
foreach ($path in $written) { Write-Host "Report: $path" }
$devices
