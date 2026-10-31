$ErrorActionPreference = 'Stop'
$root = Join-Path $env:RUNNER_TEMP 'bridge-smoke'
New-Item -ItemType Directory -Force $root | Out-Null
Get-ChildItem "$env:GITHUB_WORKSPACE/payload" -Recurse -File | Select-Object FullName,Length | Format-Table
Get-ChildItem "$env:GITHUB_WORKSPACE/payload" -Filter '*.zip' -Recurse | ForEach-Object { Expand-Archive $_.FullName -DestinationPath "$env:GITHUB_WORKSPACE/payload/expanded" -Force }
$exe = Get-ChildItem "$env:GITHUB_WORKSPACE/payload" -Recurse -Filter codex-bridge-service.exe | Select-Object -First 1
if (!$exe) { throw 'Service executable absent' }
$exeDir = $exe.Directory.FullName
Get-Content (Join-Path $exeDir 'BUILD-INFO.json')
$stdout = Join-Path $root 'stdout.txt'
$stderr = Join-Path $root 'stderr.txt'
$proc = Start-Process $exe.FullName -ArgumentList @('--foreground','--data-root',"$root/state") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WorkingDirectory $exeDir
try {
  $port = 0
  for ($n=0; $n -lt 60; $n++) {
    $proc.Refresh()
    if ($proc.HasExited) { Get-Content $stderr; throw "Service exited $($proc.ExitCode)" }
    $s = Get-Content $stdout -Raw -ErrorAction SilentlyContinue
    if ($s -match 'ready on 127\.0\.0\.1:(\d+)') { $port=[int]$Matches[1]; break }
    Start-Sleep -Milliseconds 500
  }
  if (!$port) { Get-Content $stderr; throw 'Service did not become ready' }
  Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BridgeCred {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
 struct Cred {
  public uint Flags; public uint Type; public string TargetName; public string Comment;
  public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
  public uint CredentialBlobSize; public IntPtr CredentialBlob;
  public uint Persist; public uint AttributeCount; public IntPtr Attributes;
  public string TargetAlias; public string UserName;
 }
 [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern bool Read(string target,uint type,uint flags,out IntPtr cred);
 [DllImport("advapi32.dll")] static extern void CredFree(IntPtr cred);
 public static string Load(string target) {
  IntPtr p;
  if(!Read(target,1,0,out p)) throw new Exception("Credential read failed: "+Marshal.GetLastWin32Error());
  try { var c=Marshal.PtrToStructure<Cred>(p); byte[] b=new byte[c.CredentialBlobSize];
   Marshal.Copy(c.CredentialBlob,b,0,b.Length); return Encoding.UTF8.GetString(b);
  } finally {CredFree(p);}
 }
}
'@
  $token = [BridgeCred]::Load('com.openai.codex-bridge.secrets.service-mcp-path-secret')
  Write-Output "::add-mask::$token"
  $base = "http://127.0.0.1:$port/mcp"
  $headers = @{
    'X-Codex-Bridge-Token'=$token
    'Accept'='application/json, text/event-stream'
    'Mcp-Protocol-Version'='2026-07-28'
  }
  $evidence = Join-Path $env:GITHUB_WORKSPACE 'smoke-evidence'
  New-Item -ItemType Directory -Force $evidence | Out-Null
  function Request([string]$method, [hashtable]$extra, [string]$label) {
    $params = @{
      '_meta'=@{
        'io.modelcontextprotocol/protocolVersion'='2026-07-28'
        'io.modelcontextprotocol/clientCapabilities'=@{}
        'io.modelcontextprotocol/clientInfo'=@{name='binary-smoke';version='1'}
      }
    }
    foreach ($k in $extra.Keys) { $params[$k]=$extra[$k] }
    $h = $headers.Clone()
    $h['Mcp-Method']=$method
    if($method -eq 'resources/read') { $h['Mcp-Name']=$extra.uri }
    if($method -eq 'tools/call') { $h['Mcp-Name']=$extra.name }
    $body = @{jsonrpc='2.0';id=$label;method=$method;params=$params} | ConvertTo-Json -Depth 30 -Compress
    $r=Invoke-WebRequest -Uri $base -Method Post -Headers $h -ContentType application/json -Body $body -TimeoutSec 35 -SkipHttpErrorCheck
    $text=[string]$r.Content
    $text | Set-Content (Join-Path $evidence "$label.json") -Encoding utf8
    Write-Output "$label status=$($r.StatusCode) contentType=$($r.Headers['Content-Type']) bytes=$($r.RawContentLength)"
    if($r.StatusCode -ne 200) { Write-Output $text; throw "$label returned non-200" }
    if ($text.TrimStart().StartsWith('{')) {
      $j = $text | ConvertFrom-Json -AsHashtable
    } else {
      $j = $null
      foreach($line in ($text -split "\r?\n")) {
        if(!$line.StartsWith('data:')) { continue }
        $payload=$line.Substring(5).Trim()
        if(!$payload) { continue }
        $obj=$payload | ConvertFrom-Json -AsHashtable
        if($obj.id -eq $label -and ($obj.ContainsKey('result') -or $obj.ContainsKey('error'))) { $j=$obj; break }
      }
      if(!$j) { throw "$label no terminal SSE response" }
    }
    if($j.error) { Write-Output $text; throw "$label returned JSON-RPC error" }
    if($j.result.resultType -ne 'complete') { throw "$label missing complete resultType" }
    return $j
  }
  $d=Request 'server/discover' @{} 'discover'
  $t=Request 'tools/list' @{} 'tools'
  $r=Request 'resources/list' @{} 'resources'
  $ui=Request 'resources/read' @{uri='ui://codex-bridge/file-transfer.html'} 'file-transfer'
  $status=Request 'tools/call' @{name='bridge_status';arguments=@{}} 'status'
  Write-Output "tools=$($t.result.tools.Count) resources=$($r.result.resources.Count)"
  foreach($tool in $t.result.tools) {
    if($tool.inputSchema.type -ne 'object') { throw "Bad input schema: $($tool.name)" }
    if($tool.name -notmatch '^[a-zA-Z0-9_.-]{1,128}$') { throw "Bad tool name: $($tool.name)" }
  }
  $helper=Join-Path $exeDir 'tunnel-client.exe'
  & $helper dev proxy --help | Set-Content (Join-Path $evidence 'dev-proxy-help.txt')
  Get-Content (Join-Path $evidence 'dev-proxy-help.txt')
  Write-Output 'REAL WINDOWS BINARY LOCAL MCP SMOKE PASS'
  $env:BRIDGE_SMOKE_TOKEN=$token
  $profile=Join-Path $root 'local.yaml'
  @"
config_version: 1
mcp:
  server_urls:
    - channel: main
      url: $base
  extra_headers:
    X-Codex-Bridge-Token: env:BRIDGE_SMOKE_TOKEN
  discovery_extra_headers:
    X-Codex-Bridge-Token: env:BRIDGE_SMOKE_TOKEN
"@ | Set-Content $profile -Encoding utf8
  $urlFile=Join-Path $root 'proxy.json'
  $proxyOut=Join-Path $root 'proxy.stdout.txt'
  $proxyErr=Join-Path $root 'proxy.stderr.txt'
  $proxy=Start-Process $helper -ArgumentList @('dev','proxy','--profile-file',$profile,'--url-file',$urlFile,'--duration','90s') -PassThru -RedirectStandardOutput $proxyOut -RedirectStandardError $proxyErr
  try {
    for($n=0;$n -lt 80;$n++) {
      if(Test-Path $urlFile) { break }
      if($proxy.HasExited) { Get-Content $proxyErr; throw 'Dev proxy exited' }
      Start-Sleep -Milliseconds 500
    }
    if(!(Test-Path $urlFile)) { Get-Content $proxyErr; throw 'Dev proxy did not become ready' }
    $connection=Get-Content $urlFile -Raw | ConvertFrom-Json
    $base=$connection.mcp_url
    if(!$base.StartsWith('http://127.0.0.1:')) { throw 'Unexpected proxy endpoint' }
    $d=Request 'server/discover' @{} 'tunnel-discover'
    $t=Request 'tools/list' @{} 'tunnel-tools'
    $ui=Request 'resources/read' @{uri='ui://codex-bridge/file-transfer.html'} 'tunnel-file-transfer'
    $status=Request 'tools/call' @{name='bridge_status';arguments=@{}} 'tunnel-status'
    Write-Output "TUNNEL CLIENT AND WINDOWS BINARY MCP SMOKE PASS tools=$($t.result.tools.Count)"
  } finally {
    if($proxy -and !$proxy.HasExited) { Stop-Process -Id $proxy.Id -Force }
    Get-Content $proxyErr -ErrorAction SilentlyContinue | Set-Content (Join-Path $evidence 'dev-proxy.log')
    Remove-Item Env:BRIDGE_SMOKE_TOKEN
  }
} finally {
  if($proc -and !$proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  Get-Content $stderr -ErrorAction SilentlyContinue
}
