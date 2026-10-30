#requires -Version 5.1
# Offline tests for the Files provider (.eml and .msg without Outlook). Synthetic mail only: .eml fixtures live in
# tests\fixtures\mail; .msg files are built here by a tiny compound-file writer so no binary blobs are committed.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatUsage','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatMailFiles','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-PacketRatInboxAnalysis.ps1')
function Assert-Files([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Mail files test failed: '+$Message)}}
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $threw=$null
    try{& $Block}catch{$threw=$_.Exception.Message}
    Assert-Files ($null -ne $threw) ($Message+' (expected an error)')
    Assert-Files ($threw -match $Pattern) ($Message+" (wrong error: $threw)")
}

# --- Minimal compound file (.msg) writer: FAT, directory, mini stream; 512-byte sectors, 4096 mini cutoff ----------
function New-MsgBytes([hashtable]$Props,[string[]]$To=@(),[string[]]$Attach=@(),[datetime]$Time=[datetime]::MinValue){
    $ents=New-Object System.Collections.ArrayList
    function Add-Ent($name,$type,$parent,[byte[]]$data){ [void]$ents.Add([pscustomobject]@{Name=$name;Type=$type;Parent=$parent;Data=$data;Kids=(New-Object System.Collections.ArrayList);Start=-2;Id=$ents.Count}) ; return ($ents.Count-1) }
    $u={param($s) [Text.Encoding]::Unicode.GetBytes($s+"`0")}
    $null=Add-Ent 'Root Entry' 5 -1 $null
    foreach($k in $Props.Keys){ $v=$Props[$k]; $d=if($v -is [byte[]]){$v}else{& $u $v}; $ty=if($v -is [byte[]]){'0102'}else{'001F'}; $null=Add-Ent ("__substg1.0_$k$ty") 2 0 $d }
    $n=0
    foreach($t in $To){ $r=Add-Ent ('__recip_version1.0_#{0:X8}' -f $n) 1 0 $null; $null=Add-Ent '__substg1.0_39FE001F' 2 $r (& $u $t); $n++ }
    $n=0
    foreach($a in $Attach){ $r=Add-Ent ('__attach_version1.0_#{0:X8}' -f $n) 1 0 $null; $null=Add-Ent '__substg1.0_3707001F' 2 $r (& $u $a); $n++ }
    $pr=New-Object System.IO.MemoryStream; $bw=New-Object System.IO.BinaryWriter($pr)
    $bw.Write([byte[]]::new(32))
    if($Time -ne [datetime]::MinValue){ $bw.Write([uint16]0x0040);$bw.Write([uint16]0x0E06);$bw.Write([uint32]0);$bw.Write([int64]$Time.ToUniversalTime().ToFileTimeUtc()) }
    $null=Add-Ent '__properties_version1.0' 2 0 $pr.ToArray()
    foreach($e in $ents){ if($e.Parent -ge 0){[void]$ents[$e.Parent].Kids.Add($e.Id)} }
    # sector allocation: 0 = FAT, then directory, minifat, ministream, big streams
    $dirSecs=[int][Math]::Ceiling($ents.Count*128/512.0)
    $mini=New-Object System.IO.MemoryStream; $miniFat=New-Object System.Collections.ArrayList
    foreach($e in $ents){ if($e.Type -eq 2 -and $e.Data.Length -gt 0 -and $e.Data.Length -lt 4096){
        $cnt=[int][Math]::Ceiling($e.Data.Length/64.0); $e.Start=$miniFat.Count
        for($i=0;$i -lt $cnt;$i++){ [void]$miniFat.Add($(if($i -lt $cnt-1){$miniFat.Count+1}else{-2})) }
        $mini.Write($e.Data,0,$e.Data.Length); $pad=$cnt*64-$e.Data.Length; if($pad -gt 0){$mini.Write([byte[]]::new($pad),0,$pad)} } }
    $miniBytes=$mini.ToArray(); $mfSecs=[int][Math]::Ceiling($miniFat.Count*4/512.0); $msSecs=[int][Math]::Ceiling($miniBytes.Length/512.0)
    $fat=New-Object System.Collections.ArrayList; [void]$fat.Add(-3)
    function Alloc-Chain([int]$count){ $first=$fat.Count; for($i=0;$i -lt $count;$i++){ [void]$fat.Add($(if($i -lt $count-1){$fat.Count+1}else{-2})) }; return $first }
    $dirStart=Alloc-Chain $dirSecs
    $mfStart=if($mfSecs){Alloc-Chain $mfSecs}else{-2}
    $msStart=if($msSecs){Alloc-Chain $msSecs}else{-2}
    $ents[0].Start=$msStart; $ents[0].Data=$miniBytes
    $bigs=@()
    foreach($e in $ents){ if($e.Type -eq 2 -and $e.Data.Length -ge 4096){ $sc=[int][Math]::Ceiling($e.Data.Length/512.0); $e.Start=Alloc-Chain $sc; $bigs+=$e } }
    if($fat.Count -gt 128){ throw 'test writer supports one FAT sector' }
    $total=$fat.Count
    $img=New-Object byte[] (512*($total+1))
    $magic=[byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1); [Array]::Copy($magic,$img,8)
    function Put32($off,$v){ [Array]::Copy([BitConverter]::GetBytes([int]$v),0,$img,$off,4) }
    [Array]::Copy([BitConverter]::GetBytes([uint16]0x3E),0,$img,0x18,2);[Array]::Copy([BitConverter]::GetBytes([uint16]3),0,$img,0x1A,2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]0xFFFE),0,$img,0x1C,2);[Array]::Copy([BitConverter]::GetBytes([uint16]9),0,$img,0x1E,2);[Array]::Copy([BitConverter]::GetBytes([uint16]6),0,$img,0x20,2)
    Put32 0x2C 1; Put32 0x30 $dirStart; Put32 0x38 4096; Put32 0x3C $mfStart; Put32 0x40 $mfSecs; Put32 0x44 (-2); Put32 0x48 0
    for($i=0;$i -lt 109;$i++){ Put32 (0x4C+4*$i) $(if($i -eq 0){0}else{-1}) }
    function SecAt($s){ 512*($s+1) }
    for($i=0;$i -lt 128;$i++){ Put32 ((SecAt 0)+4*$i) $(if($i -lt $fat.Count){$fat[$i]}else{-1}) }
    $dirOff=SecAt $dirStart
    for($i=0;$i -lt $dirSecs*4;$i++){ $o=$dirOff+128*$i; Put32 ($o+68) (-1); Put32 ($o+72) (-1); Put32 ($o+76) (-1) }
    foreach($e in $ents){
        $o=$dirOff+128*$e.Id; $nb=[Text.Encoding]::Unicode.GetBytes($e.Name); [Array]::Copy($nb,0,$img,$o,$nb.Length)
        [Array]::Copy([BitConverter]::GetBytes([uint16]($nb.Length+2)),0,$img,$o+64,2); $img[$o+66]=[byte]$e.Type; $img[$o+67]=1
        $kids=@($e.Kids); if($kids.Count){ Put32 ($o+76) $kids[0]; for($i=0;$i -lt $kids.Count-1;$i++){ Put32 ($dirOff+128*$kids[$i]+72) $kids[$i+1] } }
        Put32 ($o+116) $e.Start; [Array]::Copy([BitConverter]::GetBytes([int64]$(if($e.Data){$e.Data.Length}else{0})),0,$img,$o+120,8)
    }
    if($mfSecs){ for($i=0;$i -lt $miniFat.Count;$i++){ Put32 ((SecAt $mfStart)+4*$i) $miniFat[$i] } }
    if($msSecs){ [Array]::Copy($miniBytes,0,$img,(SecAt $msStart),$miniBytes.Length) }
    foreach($e in $bigs){ [Array]::Copy($e.Data,0,$img,(SecAt $e.Start),$e.Data.Length) }
    return ,$img
}

$e9=[string][char]0xE9   # the script file is ASCII on purpose: Windows PowerShell 5.1 reads BOM-less files as ANSI
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-files-'+[guid]::NewGuid().ToString('N'))
$mailDir=Join-Path $tmp 'mail'; [void](New-Item -ItemType Directory -Path $mailDir -Force)
$fixtures=Join-Path $PSScriptRoot 'fixtures\mail'
$savedEnv=@{};foreach($n in 'PACKETRAT_MAIL_FOLDER','PACKETRAT_USER_EMAIL','PACKETRAT_CLASSIFY'){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
try{
    # --- .eml parsing ---------------------------------------------------------------------------------------------
    $plain=Read-PacketRatEmlFile (Join-Path $fixtures 'plain.eml')
    Assert-Files ($plain.Subject -eq 'Approve the synthetic budget by Nov 5' -and $plain.FromEmail -eq 'dana@example.test' -and $plain.FromName -eq 'Dana Example') 'plain eml headers'
    Assert-Files ($plain.Body -match 'approve the budget' -and @($plain.To).Count -eq 2 -and $plain.Importance -eq 2) 'plain eml body, recipients, importance'
    Assert-Files ($plain.Date.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') -eq '2026-10-28 09:15') 'RFC 5322 date'
    Assert-Files ($plain.SourceLine -eq 3 -and $plain.SourceOffset -gt 0) 'eml records the subject line and byte offset'
    $mp=Read-PacketRatEmlFile (Join-Path $fixtures 'multipart-attachment.eml')
    Assert-Files ($mp.Subject -eq "Caf$e9 menu for the review" -and $mp.FromName -eq "Jos$e9 Example") 'RFC 2047 subject and sender name'
    Assert-Files ($mp.Body -match "Caf$e9 menu attached\. Please reply with your choice by Friday\." -and $mp.Body -notmatch 'HTML copy') 'quoted-printable text part wins over html, soft breaks joined'
    Assert-Files ((@($mp.Attachments) -join ',') -eq 'menu.pdf') 'attachment listed by name only'
    Assert-Files ($mp.Date.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') -eq '2026-10-27 20:40') 'date with a trailing zone comment'
    $ho=Read-PacketRatEmlFile (Join-Path $fixtures 'html-only.eml')
    Assert-Files ($ho.HasHtml -and $ho.Body -match 'Digest & news' -and $ho.Body -notmatch '<|color:red') 'base64 html-only body becomes text without markup or styles'
    $empty=Join-Path $mailDir 'empty.eml'; [IO.File]::WriteAllBytes($empty,[byte[]]@())
    Assert-Throws { Read-PacketRatEmlFile $empty } 'empty' 'an empty eml gives a clear error'
    $junk=Join-Path $mailDir 'junk.eml'; [IO.File]::WriteAllText($junk,'just some text without headers')
    Assert-Throws { Read-PacketRatEmlFile $junk } 'No mail headers' 'a non-mail eml gives a clear error'

    # --- .msg parsing ---------------------------------------------------------------------------------------------
    $big='Line of a long synthetic body. ' * 400   # > 4096 bytes: regular sectors; the short ones go through the mini stream
    $msgBytes=New-MsgBytes -Props @{'0037'='Quarterly review slides';'0C1A'='Riley Sample';'5D01'='riley@example.test';'1000'=$big} -To @('me@example.test','team@example.test') -Attach @('slides.pptx','notes.txt') -Time ([datetime]'2026-10-29T13:05:00Z')
    $msgPath=Join-Path $mailDir 'review.msg'; [IO.File]::WriteAllBytes($msgPath,$msgBytes)
    $m=Read-PacketRatMsgFile $msgPath
    Assert-Files ($m.Subject -eq 'Quarterly review slides' -and $m.FromName -eq 'Riley Sample' -and $m.FromEmail -eq 'riley@example.test') 'msg subject and sender from the mini stream'
    Assert-Files ($m.Body.StartsWith('Line of a long synthetic body.') -and $m.Body.Length -eq $big.Length) 'msg body from regular sectors'
    Assert-Files ((@($m.To) -join ',') -eq 'me@example.test,team@example.test') 'msg recipients'
    Assert-Files ((@($m.Attachments) -join ',') -eq 'slides.pptx,notes.txt') 'msg attachments by name'
    Assert-Files ($m.Date.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') -eq '2026-10-29 13:05') 'msg delivery time'
    Assert-Files ($m.SourceOffset -gt 512 -and $m.SourceOffset -lt $msgBytes.Length) 'msg records the byte offset of the subject'
    $at=[Text.Encoding]::Unicode.GetBytes('Quarterly'); $hit=$false
    for($i=$m.SourceOffset;$i -lt $m.SourceOffset+4;$i++){ }
    $found=[Text.Encoding]::Unicode.GetString($msgBytes,[int]$m.SourceOffset,18)
    Assert-Files ($found -eq 'Quarterly') 'the recorded offset points at the subject text in the file'
    $htmlMsg=New-MsgBytes -Props @{'0037'='Html only';'0C1A'='Sam Sample';'5D01'='sam@example.test';'1013'=[Text.Encoding]::UTF8.GetBytes('<p>Please <b>confirm</b></p>')} -Time ([datetime]'2026-10-25T10:00:00Z')
    $hp=Join-Path $mailDir 'html.msg'; [IO.File]::WriteAllBytes($hp,$htmlMsg)
    Assert-Files ((Read-PacketRatMsgFile $hp).Body -eq 'Please confirm') 'msg html-only body converted to text'
    $trunc=Join-Path $mailDir 'truncated.msg'; [IO.File]::WriteAllBytes($trunc,$msgBytes[0..1023])
    Assert-Throws { Read-PacketRatMsgFile $trunc } 'outside the file|truncated|damaged|too small' 'a truncated msg gives a clear error'
    $notmsg=Join-Path $mailDir 'notmsg.msg'; [IO.File]::WriteAllText($notmsg,('x'*2000))
    Assert-Throws { Read-PacketRatMsgFile $notmsg } 'Not an Outlook .msg' 'a non-msg file gives a clear error'

    # --- Provider -------------------------------------------------------------------------------------------------
    foreach($f in 'plain.eml','multipart-attachment.eml','html-only.eml'){ Copy-Item (Join-Path $fixtures $f) $mailDir }
    [IO.File]::WriteAllText((Join-Path $mailDir 'readme.txt'),'ignored')
    $sens=Join-Path $mailDir 'sensitive.eml'
    [IO.File]::WriteAllText($sens,"From: x@example.test`r`nTo: me@example.test`r`nSubject: Passport renewal forms`r`nDate: Thu, 29 Oct 2026 08:00:00 +0000`r`n`r`nSecret body text`r`n")
    $env:PACKETRAT_USER_EMAIL='me@example.test'
    $s=Get-PacketRatInboxSummaryFiles -Folder $mailDir
    Assert-Files ($s.Provider -eq 'Files' -and $s.FilesFound -eq 10) 'only .eml and .msg files are read'
    Assert-Files (@($s.Errors).Count -eq 4 -and (@($s.Errors.File) -contains 'empty.eml') -and (@($s.Errors.File) -contains 'truncated.msg')) 'malformed files become errors, not a crash'
    Assert-Files ($s.AnalyzedCount -eq 5 -and $s.SkippedCount -eq 1) 'good, sensitive counted separately'
    Assert-Files ($s.Skipped[0].BodyPreview -match 'REDACTED' -and $s.Skipped[0].Subject -match 'Passport') 'sensitive mail preview is redacted'
    $e1=$s.Emails[0]
    Assert-Files ($e1.Subject -eq 'Quarterly review slides') 'newest first'
    Assert-Files ($e1.SourcePath -eq $msgPath -and $e1.SourceFormat -eq 'msg' -and $e1.SourceOffset -gt 0) 'summary keeps the source path and offset'
    Assert-Files ((@($s.Emails | Where-Object SourceFormat -eq 'eml')[0]).SourceLine -ge 1) 'eml summary keeps a source line'
    $b=$s.Emails | Where-Object Subject -match 'Approve the synthetic'
    Assert-Files ($b.IsDirect -and $b.Importance -eq 2 -and $b.Fingerprint -and $b.EntryID -like 'file:*') 'direct recipient, importance, fingerprint'
    Assert-Files (@($s.Emails | Where-Object Subject -match 'menu for the review')[0].AttachmentNames -contains 'menu.pdf') 'attachment names reach the summary'
    Assert-Files ($e1.BodyPreview.Length -le 283) 'previews are truncated'
    Assert-Files ((Get-PacketRatInboxSummaryFiles -Folder $mailDir -MaxEmails 2).AnalyzedCount -le 2) 'MaxEmails limits the read'
    $env:PACKETRAT_MAIL_FOLDER=$mailDir
    Assert-Files ((Get-PacketRatInboxSummaryFiles).AnalyzedCount -eq 5) 'PACKETRAT_MAIL_FOLDER is the default folder'
    $env:PACKETRAT_MAIL_FOLDER=$null
    Assert-Throws { Get-PacketRatInboxSummaryFiles } 'no folder set' 'no folder is a clear error'
    Assert-Throws { Get-PacketRatInboxSummaryFiles -Folder (Join-Path $tmp 'nope') } 'folder not found' 'a missing folder is a clear error'
    $emptyDir=Join-Path $tmp 'none'; [void](New-Item -ItemType Directory $emptyDir)
    Assert-Files ((Get-PacketRatInboxSummaryFiles -Folder $emptyDir).AnalyzedCount -eq 0) 'an empty folder yields zero messages'

    # --- End to end: analysis, AI stubbed ---------------------------------------------------------------------------
    function Invoke-PacketRatChat {
        param([object[]]$Messages,[string]$Profile,[string]$Model,[int]$MaxTokens,[double]$Temperature)
        $user=[string]$Messages[1].content
        $rows=@(ConvertFrom-Json -InputObject $user.Substring($user.IndexOf('EMAIL DATA (JSON):')+18).Trim() | ForEach-Object { $_ })
        $recs=foreach($row in $rows){
            $cat=if($row.Subject -match 'Approve'){'must_reply'}else{'no_action'}
            '{{"index":{0},"category":"{1}","urgency":"High","reason":"Reason {0}","requested_action":"Act","deadline":"","evidence":"e","confidence":"high"}}' -f $row.Index,$cat
        }
        [pscustomobject]@{Text="<<<PACKETRAT_CLASSIFY_V1>>>`n{`"version`":`"PACKETRAT_CLASSIFY_V1`",`"records`":[$($recs -join ',')]}`n<<<END_PACKETRAT_CLASSIFY_V1>>>";Profile='Test';Model='TestModel'}
    }
    $r=Invoke-PacketRatInboxAnalysis -Provider Files -Folder $mailDir -Classification Batch -Root $tmp -Profile AiEndpoint
    Assert-Files ($r.Success -and $r.Provider -eq 'Files' -and $r.AnalyzedCount -eq 5) 'files analysis succeeds without Outlook'
    Assert-Files (@($r.MustReply | Where-Object Subject -match 'Approve the synthetic').Count -eq 1) 'the budget mail reaches the action queue (local direct-request rule also queues the direct .msg)'
    Assert-Files ($r.Report -match '## Must Reply') 'the same report is produced'

    # --- API route and CLI command ----------------------------------------------------------------------------------
    $cmd=Find-PacketRatCommand 'inbox analyze'
    $body=ConvertTo-PacketRatCommandBody $cmd @{provider='Files';folder=$mailDir}
    Assert-Files ($body.provider -eq 'Files' -and $body.folder -eq $mailDir) 'CLI --provider Files --folder maps to the API body'
    Assert-Throws { ConvertTo-PacketRatCommandBody $cmd @{provider='Nope'} } 'must be one of' 'unknown providers are refused by the CLI'
    $api=Invoke-PacketRatApi -Route '/api/analyze' -Data ([pscustomobject]@{provider='Files';folder=$mailDir;classification='Batch';profile='AiEndpoint';maxEmails=40;daysBack=14})
    Assert-Files ($api.ok -and $api.summary.Provider -eq 'Files') 'the API route runs the Files provider'
    Assert-Throws { Invoke-PacketRatApi -Route '/api/item/archive' -Data ([pscustomobject]@{key=$r.MustReply[0].Key}) } 'classic Outlook' 'inbox actions are refused for file mail'
    Write-Host 'Mail files tests passed.'
}finally{
    foreach($n in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
