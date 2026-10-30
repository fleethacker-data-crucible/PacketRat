# PacketRat - Files provider: read exported .eml and .msg files from a folder, no Outlook needed
#requires -Version 5.1
# .eml is parsed here with .NET only. .msg (an OLE compound file) is parsed by C# source compiled in memory with
# Add-Type: no DLL is shipped, loaded or cached on disk. A file that cannot be read becomes an entry in Errors with a
# clear reason; it never stops the run.

if (-not ('PacketRatMsgReader' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

public class PacketRatMsgResult
{
    public Dictionary<string, string> Props = new Dictionary<string, string>();
    public Dictionary<string, byte[]> Bin = new Dictionary<string, byte[]>();
    public DateTime? Time;
    public List<string> Recipients = new List<string>();
    public List<string> Attachments = new List<string>();
    public long SubjectOffset = -1;
}

public static class PacketRatMsgReader
{
    class Entry { public string Name; public int Type; public int Left, Right, Child; public int Start; public long Size; public long Offset; }

    static readonly byte[] Magic = { 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

    public static PacketRatMsgResult Read(byte[] d)
    {
        if (d == null || d.Length < 512) throw new FormatException("File is too small to be an Outlook .msg file.");
        for (int i = 0; i < 8; i++) if (d[i] != Magic[i]) throw new FormatException("Not an Outlook .msg file (missing compound file signature).");
        int shift = BitConverter.ToUInt16(d, 0x1E), mshift = BitConverter.ToUInt16(d, 0x20);
        if (shift < 7 || shift > 16 || mshift > shift) throw new FormatException("Unsupported compound file sector size.");
        int ss = 1 << shift, ms = 1 << mshift;
        int dirStart = BitConverter.ToInt32(d, 0x30), miniCut = BitConverter.ToInt32(d, 0x38);
        int miniFatStart = BitConverter.ToInt32(d, 0x3C), numMiniFat = BitConverter.ToInt32(d, 0x40);
        int difStart = BitConverter.ToInt32(d, 0x44), numDif = BitConverter.ToInt32(d, 0x48);
        int numFat = BitConverter.ToInt32(d, 0x2C);

        var fatSectors = new List<int>();
        for (int i = 0; i < 109 && fatSectors.Count < numFat; i++) { int s = BitConverter.ToInt32(d, 0x4C + 4 * i); if (s >= 0) fatSectors.Add(s); }
        int dif = difStart;
        for (int n = 0; n < numDif && dif >= 0 && fatSectors.Count < numFat; n++)
        {
            long off = SecOff(dif, ss, d.Length);
            for (int i = 0; i < ss / 4 - 1 && fatSectors.Count < numFat; i++) { int s = BitConverter.ToInt32(d, (int)off + 4 * i); if (s >= 0) fatSectors.Add(s); }
            dif = BitConverter.ToInt32(d, (int)off + ss - 4);
        }
        var fat = new List<int>();
        foreach (int s in fatSectors) { long off = SecOff(s, ss, d.Length); for (int i = 0; i < ss / 4; i++) fat.Add(BitConverter.ToInt32(d, (int)off + 4 * i)); }

        Func<int, List<int>> chain = start =>
        {
            var l = new List<int>(); int s = start;
            while (s >= 0 && s < fat.Count && l.Count <= fat.Count) { l.Add(s); s = fat[s]; }
            return l;
        };
        Func<int, byte[]> readChain = start =>
        {
            var c = chain(start); var buf = new byte[c.Count * ss];
            for (int i = 0; i < c.Count; i++) Buffer.BlockCopy(d, (int)SecOff(c[i], ss, d.Length), buf, i * ss, ss);
            return buf;
        };

        byte[] dir = readChain(dirStart);
        if (dir.Length < 128) throw new FormatException("Compound file directory is missing or damaged.");
        var dirChain = chain(dirStart);
        var entries = new List<Entry>();
        for (int i = 0; i + 128 <= dir.Length; i += 128)
        {
            int nl = BitConverter.ToUInt16(dir, i + 64);
            var e = new Entry();
            e.Name = nl >= 2 ? Encoding.Unicode.GetString(dir, i, Math.Min(nl, 64) - 2) : "";
            e.Type = dir[i + 66]; e.Left = BitConverter.ToInt32(dir, i + 68); e.Right = BitConverter.ToInt32(dir, i + 72);
            e.Child = BitConverter.ToInt32(dir, i + 76); e.Start = BitConverter.ToInt32(dir, i + 116); e.Size = BitConverter.ToInt64(dir, i + 120);
            int idx = i / 128, perSec = ss / 128;
            e.Offset = (idx / perSec < dirChain.Count) ? SecOff(dirChain[idx / perSec], ss, d.Length) + (idx % perSec) * 128 : -1;
            entries.Add(e);
        }
        var root = entries[0];
        byte[] mini = root.Size > 0 ? readChain(root.Start) : new byte[0];
        var miniFat = new List<int>();
        if (numMiniFat > 0) { byte[] mf = readChain(miniFatStart); for (int i = 0; i + 4 <= mf.Length; i += 4) miniFat.Add(BitConverter.ToInt32(mf, i)); }

        Func<Entry, byte[]> data = e =>
        {
            if (e.Size <= 0) return new byte[0];
            if (e.Size > d.Length) throw new FormatException("Stream '" + e.Name + "' is larger than the file.");
            if (e.Size < miniCut)
            {
                var res = new byte[e.Size]; int s = e.Start, got = 0, guard = 0;
                while (s >= 0 && s < miniFat.Count && got < e.Size && guard++ <= miniFat.Count)
                {
                    int n = (int)Math.Min(ms, e.Size - got);
                    if ((long)s * ms + n > mini.Length) throw new FormatException("Stream '" + e.Name + "' runs past the mini stream.");
                    Buffer.BlockCopy(mini, s * ms, res, got, n); got += n; s = miniFat[s];
                }
                if (got < e.Size) throw new FormatException("Stream '" + e.Name + "' is truncated.");
                return res;
            }
            byte[] full = readChain(e.Start);
            if (full.Length < e.Size) throw new FormatException("Stream '" + e.Name + "' is truncated.");
            var r2 = new byte[e.Size]; Buffer.BlockCopy(full, 0, r2, 0, (int)e.Size); return r2;
        };

        Func<Entry, List<Entry>> children = parent =>
        {
            var list = new List<Entry>(); var stack = new Stack<int>(); var seen = new HashSet<int>();
            if (parent.Child >= 0) stack.Push(parent.Child);
            while (stack.Count > 0)
            {
                int id = stack.Pop();
                if (id < 0 || id >= entries.Count || !seen.Add(id)) continue;
                list.Add(entries[id]); stack.Push(entries[id].Left); stack.Push(entries[id].Right);
            }
            return list;
        };

        var result = new PacketRatMsgResult();
        Action<Entry, PacketRatMsgResult, bool> collect = null;
        collect = (storage, target, top) =>
        {
            foreach (var c in children(storage))
            {
                if (c.Type == 2 && c.Name.StartsWith("__substg1.0_", StringComparison.OrdinalIgnoreCase) && c.Name.Length == 20)
                {
                    string id = c.Name.Substring(12, 4).ToUpperInvariant(), ty = c.Name.Substring(16, 4).ToUpperInvariant();
                    byte[] b = data(c);
                    if (ty == "001F") target.Props[id] = Encoding.Unicode.GetString(b).TrimEnd('\0');
                    else if (ty == "001E") { if (!target.Props.ContainsKey(id)) target.Props[id] = Encoding.GetEncoding(1252).GetString(b).TrimEnd('\0'); }
                    else if (ty == "0102") target.Bin[id] = b;
                    if (top && id == "0037" && target.SubjectOffset < 0 && b.Length > 0)
                    {
                        if (c.Size < miniCut)
                        {
                            var rc = chain(root.Start); long pos = (long)c.Start * ms;
                            int ci = (int)(pos / ss);
                            if (ci < rc.Count) target.SubjectOffset = SecOff(rc[ci], ss, d.Length) + pos % ss;
                        }
                        else target.SubjectOffset = SecOff(c.Start, ss, d.Length);
                    }
                }
                else if (c.Type == 2 && top && c.Name == "__properties_version1.0")
                {
                    byte[] p = data(c);
                    for (int i = 32; i + 16 <= p.Length; i += 16)
                    {
                        int tag = BitConverter.ToUInt16(p, i + 2), ty = BitConverter.ToUInt16(p, i);
                        if (ty == 0x0040 && (tag == 0x0E06 || tag == 0x0039))
                        {
                            long ft = BitConverter.ToInt64(p, i + 8);
                            try { DateTime t = DateTime.FromFileTimeUtc(ft); if (tag == 0x0E06 || !target.Time.HasValue) target.Time = t; } catch { }
                        }
                    }
                }
                else if (c.Type == 1 && top && c.Name.StartsWith("__recip_version1.0_", StringComparison.OrdinalIgnoreCase))
                {
                    var rr = new PacketRatMsgResult(); collect(c, rr, false);
                    string addr; string nm;
                    rr.Props.TryGetValue("39FE", out addr); rr.Props.TryGetValue("3001", out nm);
                    target.Recipients.Add(!string.IsNullOrEmpty(addr) ? addr : nm);
                }
                else if (c.Type == 1 && top && c.Name.StartsWith("__attach_version1.0_", StringComparison.OrdinalIgnoreCase))
                {
                    var ar = new PacketRatMsgResult(); collect(ar == null ? c : c, ar, false);
                    string nm; if (!ar.Props.TryGetValue("3707", out nm) || string.IsNullOrEmpty(nm)) ar.Props.TryGetValue("3704", out nm);
                    if (!ar.Props.ContainsKey("3707") && !ar.Props.ContainsKey("3704")) ar.Props.TryGetValue("3001", out nm);
                    target.Attachments.Add(string.IsNullOrEmpty(nm) ? "(unnamed attachment)" : nm);
                }
            }
        };
        collect(root, result, true);
        if (result.Props.Count == 0 && result.Bin.Count == 0) throw new FormatException("No message properties found; this does not look like a mail .msg file.");
        return result;
    }

    static long SecOff(int sector, int ss, int len)
    {
        long off = ((long)sector + 1) * ss;
        if (sector < 0 || off + ss > len) throw new FormatException("Compound file sector " + sector + " is outside the file (truncated or damaged).");
        return off;
    }
}
'@
}

function ConvertFrom-PacketRatHeaderWord([string]$Text) {
    # RFC 2047 encoded words: =?charset?B|Q?text?=
    if (-not $Text -or $Text -notmatch '=\?') { return $Text }
    $t = [regex]::Replace($Text, '(\?=)\s+(=\?)', '$1$2')
    return [regex]::Replace($t, '=\?([^?]+)\?([bBqQ])\?([^?]*)\?=', {
        param($m)
        try {
            $enc = [Text.Encoding]::GetEncoding($m.Groups[1].Value)
            if ($m.Groups[2].Value -ieq 'B') { return $enc.GetString([Convert]::FromBase64String($m.Groups[3].Value)) }
            $bytes = ConvertFrom-PacketRatQuotedPrintable -Text ($m.Groups[3].Value -replace '_', ' ') -AsBytes
            return $enc.GetString($bytes)
        } catch { return $m.Value }
    })
}

function ConvertFrom-PacketRatQuotedPrintable([string]$Text, [switch]$AsBytes) {
    $ms = New-Object System.IO.MemoryStream
    $t = $Text -replace "=\r?\n", ''
    $i = 0
    while ($i -lt $t.Length) {
        $c = $t[$i]
        if ($c -eq '=' -and $i + 2 -lt $t.Length + 0 -and $t.Substring($i + 1, 2) -match '^[0-9A-Fa-f]{2}$') {
            $ms.WriteByte([Convert]::ToByte($t.Substring($i + 1, 2), 16)); $i += 3
        } else { $ms.WriteByte([byte]([int]$c -band 0xFF)); $i++ }
    }
    $bytes = $ms.ToArray()
    if ($AsBytes) { return , $bytes }
    return , $bytes
}

function Split-PacketRatMimeHeaders([string]$Text) {
    # Returns @{ Headers = ordered name->value (first wins, folded lines joined); Body = text after the blank line; BodyStart = char index }
    $m = [regex]::Match($Text, "\r?\n\r?\n")
    $headText = if ($m.Success) { $Text.Substring(0, $m.Index) } else { $Text }
    $bodyStart = if ($m.Success) { $m.Index + $m.Length } else { $Text.Length }
    $unfolded = [regex]::Replace($headText, "\r?\n[ \t]+", ' ')
    $h = @{}
    foreach ($line in ($unfolded -split "\r?\n")) {
        $i = $line.IndexOf(':')
        if ($i -gt 0) { $k = $line.Substring(0, $i).Trim().ToLowerInvariant(); if (-not $h.ContainsKey($k)) { $h[$k] = $line.Substring($i + 1).Trim() } }
    }
    return @{ Headers = $h; Body = $Text.Substring($bodyStart); BodyStart = $bodyStart }
}

function Get-PacketRatHeaderParam([string]$Value, [string]$Name) {
    if (-not $Value) { return '' }
    $m = [regex]::Match($Value, '(?i)(?:^|;)\s*' + [regex]::Escape($Name) + '\s*=\s*(?:"([^"]*)"|([^;\s]*))')
    if ($m.Success) { return $(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }) }
    return ''
}

function ConvertFrom-PacketRatMimePart([string]$Raw, $Result, [int]$Depth = 0) {
    # $Raw is the part as Latin-1 text (one char per byte), so bytes survive until the charset is known.
    if ($Depth -gt 8) { return }
    $p = Split-PacketRatMimeHeaders $Raw
    $h = $p.Headers
    $ctype = if ($h['content-type']) { $h['content-type'] } else { 'text/plain' }
    $mime = ($ctype -split ';')[0].Trim().ToLowerInvariant()
    $disp = [string]$h['content-disposition']
    $fileName = ConvertFrom-PacketRatHeaderWord (Get-PacketRatHeaderParam $disp 'filename')
    if (-not $fileName) { $fileName = ConvertFrom-PacketRatHeaderWord (Get-PacketRatHeaderParam $ctype 'name') }
    if ($mime -like 'multipart/*') {
        $boundary = Get-PacketRatHeaderParam $ctype 'boundary'
        if (-not $boundary) { $Result.Warnings.Add('A multipart section has no boundary and was skipped.'); return }
        $chunks = [regex]::Split($p.Body, '(?m)^--' + [regex]::Escape($boundary) + '(?:--)?[ \t]*\r?$\r?\n?')
        for ($i = 1; $i -lt $chunks.Count; $i++) { if ($chunks[$i].Trim().Length -gt 0) { ConvertFrom-PacketRatMimePart -Raw $chunks[$i] -Result $Result -Depth ($Depth + 1) } }
        return
    }
    if ($fileName -or $disp -match '(?i)^\s*attachment') {
        $Result.Attachments.Add($(if ($fileName) { $fileName } else { '(unnamed attachment)' }))
        return
    }
    if ($mime -ne 'text/plain' -and $mime -ne 'text/html') { return }
    $cte = ([string]$h['content-transfer-encoding']).Trim().ToLowerInvariant()
    $latin = [Text.Encoding]::GetEncoding(28591)
    $bytes = switch ($cte) {
        'base64' { try { [Convert]::FromBase64String(($p.Body -replace '\s', '')) } catch { $Result.Warnings.Add('A base64 body part is damaged and was skipped.'); $null } }
        'quoted-printable' { ConvertFrom-PacketRatQuotedPrintable -Text $p.Body -AsBytes }
        default { $latin.GetBytes($p.Body) }
    }
    if ($null -eq $bytes) { return }
    $cs = Get-PacketRatHeaderParam $ctype 'charset'
    $enc = try { if ($cs) { [Text.Encoding]::GetEncoding($cs) } else { New-Object Text.UTF8Encoding($false) } } catch { New-Object Text.UTF8Encoding($false) }
    $text = $enc.GetString([byte[]]$bytes)
    if ($mime -eq 'text/html') { if (-not $Result.Html) { $Result.Html = $text } } else { if (-not $Result.Text) { $Result.Text = $text } }
}

function ConvertFrom-PacketRatHtml([string]$Html) {
    if (-not $Html) { return '' }
    $t = [regex]::Replace($Html, '(?is)<(script|style)\b.*?</\1>', ' ')
    $t = [regex]::Replace($t, '(?i)<br\s*/?>|</(p|div|tr|li|h\d)>', "`n")
    $t = [regex]::Replace($t, '<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    return ([regex]::Replace(([regex]::Replace($t, '[ \t\r\f]+', ' ')), '\s*\n\s*', "`n")).Trim()
}

function Get-PacketRatAddressList([string]$Value) {
    $out = @()
    foreach ($m in [regex]::Matches((ConvertFrom-PacketRatHeaderWord $Value), '(?:"([^"]*)"|([^<>,;"]*?))\s*<([^<>\s]+@[^<>\s]+)>|([^\s<>,;"]+@[^\s<>,;"]+)')) {
        if ($m.Groups[3].Success) { $out += [pscustomobject]@{ Name = ($m.Groups[1].Value + $m.Groups[2].Value).Trim(' ', '"'); Address = $m.Groups[3].Value } }
        else { $out += [pscustomobject]@{ Name = ''; Address = $m.Groups[4].Value } }
    }
    return $out
}

function Read-PacketRatEmlFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { throw 'The file is empty.' }
    $raw = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $top = Split-PacketRatMimeHeaders $raw
    $h = $top.Headers
    if (-not ($h.ContainsKey('from') -or $h.ContainsKey('subject') -or $h.ContainsKey('date') -or $h.ContainsKey('message-id'))) {
        throw 'No mail headers found (not an RFC 5322 message).'
    }
    $result = [pscustomobject]@{ Text = ''; Html = ''; Attachments = (New-Object System.Collections.Generic.List[string]); Warnings = (New-Object System.Collections.Generic.List[string]) }
    ConvertFrom-PacketRatMimePart -Raw $raw -Result $result
    $subjLine = 1
    $lines = $raw -split "\r?\n"
    for ($i = 0; $i -lt [Math]::Min($lines.Count, 400); $i++) { if ($lines[$i] -match '^(?i)subject:') { $subjLine = $i + 1; break }; if ($lines[$i] -eq '') { break } }
    $subjOffset = [Math]::Max(0, $raw.IndexOf("`nSubject:", [StringComparison]::OrdinalIgnoreCase) + 1)
    $from = @(Get-PacketRatAddressList $h['from'] | Select-Object -First 1)
    $date = $null
    $ds = [regex]::Replace([string]$h['date'], '\s*\([^)]*\)\s*$', '')
    $dto = [DateTimeOffset]::MinValue
    if ($ds -and [DateTimeOffset]::TryParse($ds, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dto)) { $date = $dto.LocalDateTime }
    $body = if ($result.Text) { $result.Text } else { ConvertFrom-PacketRatHtml $result.Html }
    [pscustomobject]@{
        Subject = ConvertFrom-PacketRatHeaderWord ([string]$h['subject']); FromName = $(if ($from.Count) { $from[0].Name } else { '' }); FromEmail = $(if ($from.Count) { $from[0].Address } else { '' })
        To = @(Get-PacketRatAddressList $h['to'] | ForEach-Object { $_.Address }); Date = $date; Body = $body; HasHtml = [bool]$result.Html
        MessageId = [string]$h['message-id']; Attachments = @($result.Attachments); Warnings = @($result.Warnings)
        Importance = $(if ("$($h['importance']) $($h['x-priority'])" -match '(?i)high|^\s*[12]\b') { 2 } elseif ("$($h['importance']) $($h['x-priority'])" -match '(?i)low|^\s*[45]\b') { 0 } else { 1 })
        SourceLine = $subjLine; SourceOffset = $subjOffset
    }
}

function Read-PacketRatMsgFile([string]$Path) {
    $r = [PacketRatMsgReader]::Read([IO.File]::ReadAllBytes($Path))
    $html = ''
    if ($r.Bin.ContainsKey('1013')) { $html = [Text.Encoding]::UTF8.GetString($r.Bin['1013']) }
    elseif ($r.Props.ContainsKey('1013')) { $html = $r.Props['1013'] }
    $body = if ($r.Props.ContainsKey('1000') -and $r.Props['1000'].Trim()) { $r.Props['1000'] } else { ConvertFrom-PacketRatHtml $html }
    $email = ''
    foreach ($k in @('5D01', '0C1F', '0065')) { if ($r.Props.ContainsKey($k) -and $r.Props[$k] -match '@') { $email = $r.Props[$k]; break } }
    $date = $null
    if ($null -ne $r.Time) { $date = ([datetime]$r.Time).ToLocalTime() }
    $to = @($r.Recipients | Where-Object { $_ })
    if ($to.Count -eq 0 -and $r.Props.ContainsKey('0E04')) { $to = @($r.Props['0E04'] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $imp = 1
    [pscustomobject]@{
        Subject = [string]$r.Props['0037']; FromName = [string]$r.Props['0C1A']; FromEmail = $email; To = $to; Date = $date; Body = $body
        HasHtml = [bool]$html; MessageId = ''; Attachments = @($r.Attachments); Warnings = @(); Importance = $imp
        SourceLine = 0; SourceOffset = [long][Math]::Max(0, $r.SubjectOffset)
    }
}

function Get-PacketRatInboxSummaryFiles {
    [CmdletBinding()]
    param(
        [string]$Folder,
        [int]$MaxEmails = 40,
        [int]$BodyPreviewChars = 280,
        $Store = $null
    )
    if (-not $Folder) { $Folder = [string]$env:PACKETRAT_MAIL_FOLDER }
    if (-not $Folder) { throw 'Files provider: no folder set. Pass a folder or set PACKETRAT_MAIL_FOLDER.' }
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "Files provider: folder not found: $Folder" }

    $files = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction Stop | Where-Object { $_.Extension -in '.eml', '.msg' })
    $results = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $parsed = New-Object System.Collections.Generic.List[object]

    foreach ($f in $files) {
        try {
            $m = if ($f.Extension -eq '.msg') { Read-PacketRatMsgFile -Path $f.FullName } else { Read-PacketRatEmlFile -Path $f.FullName }
            $m | Add-Member -NotePropertyName File -NotePropertyValue $f -PassThru | Out-Null
            [void]$parsed.Add($m)
        } catch {
            [void]$errors.Add([pscustomobject]@{ File = $f.Name; Path = $f.FullName; Error = $(if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }) })
        }
    }

    $myAddress = [string]$env:PACKETRAT_USER_EMAIL
    $i = 0
    foreach ($m in @($parsed | Sort-Object { if ($_.Date) { $_.Date } else { $_.File.LastWriteTime } } -Descending | Select-Object -First $MaxEmails)) {
        $i++
        $when = if ($m.Date) { $m.Date } else { $m.File.LastWriteTime }
        $received = $when.ToString('yyyy-MM-dd HH:mm')
        $subject = [string]$m.Subject
        $preview = (([string]$m.Body) -replace '\s+', ' ').Trim()
        if ($preview.Length -gt $BodyPreviewChars) { $preview = $preview.Substring(0, $BodyPreviewChars) + '...' }
        $isSensitive = $false
        if ($subject -match '(?i)\b(ssn|social security|phi|hipaa|passport|credit card)\b') { $isSensitive = $true; $preview = '[REDACTED - PII heuristic]' }
        $isDirect = [bool]($myAddress -and (@($m.To) -icontains $myAddress))
        $entryId = 'file:' + $m.File.FullName
        $fp = Get-PacketRatMailFingerprint -EntryID $entryId -Subject $subject -FromEmail $m.FromEmail -Received $received
        $userDismissed = $false
        if ($Store) {
            $userDismissed = Test-PacketRatDismissed -Store $Store -Key $fp
            if (-not $userDismissed) { $userDismissed = Test-PacketRatDismissed -Store $Store -Key "id:$entryId" }
        }
        $obj = [pscustomobject]@{
            Index = $i; EntryID = $entryId; InternetMessageId = [string]$m.MessageId; Fingerprint = $fp
            Received = $received; FromName = $m.FromName; FromEmail = $m.FromEmail; IsDirect = $isDirect
            Subject = $subject; UnRead = $true; Importance = [int]$m.Importance; ConversationTopic = $subject
            ConversationID = ''; AppearsReplied = $false; ReplyEvidence = ''; UserDismissed = $userDismissed
            IsSensitive = $isSensitive; BodyPreview = $preview
            AttachmentNames = @($m.Attachments); SourcePath = $m.File.FullName; SourceFormat = $m.File.Extension.TrimStart('.').ToLowerInvariant()
            SourceLine = [int]$m.SourceLine; SourceOffset = [long]$m.SourceOffset
        }
        if ($isSensitive) { [void]$skipped.Add($obj) } else { [void]$results.Add($obj) }
    }

    return [pscustomobject]@{
        Provider = 'Files'; Folder = $Folder; FilesFound = $files.Count
        AnalyzedCount = $results.Count; SkippedCount = $skipped.Count
        Emails = $results.ToArray(); Skipped = $skipped.ToArray(); Errors = $errors.ToArray()
        GeneratedAt = (Get-Date).ToString('o')
    }
}
