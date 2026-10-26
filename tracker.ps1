# -Watch (used by the scheduled task): keep running and re-check stores with "everySeconds" every few seconds,
# the rest at their usual interval; without it, one run checks everything that is due and exits.
param([switch]$TestNotify, [switch]$TestCall, [switch]$TestWhatsApp, [switch]$TestTelegram, [switch]$SetupTelegram, [switch]$Quiet, [switch]$Watch)

$ErrorActionPreference = 'Stop'
# Progress output blocks forever under the hidden (headless) console used by the scheduled task.
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root       = $PSScriptRoot
$StatePath  = Join-Path $Root 'state.json'
$StatusPath = Join-Path $Root 'status.txt'
$LogPath    = Join-Path $Root 'tracker.log'
$HealthPath = Join-Path $Root 'health.json'
$DashboardUrl = ([uri](Join-Path $Root 'dashboard.html')).AbsoluteUri
# Secrets kept DPAPI-encrypted in config.json as <field>Encrypted: (section, field).
$SecretFields = @(('phoneCall', 'twilioAuthToken'), ('telegram', 'botToken'), ('whatsapp', 'metaToken'))
$UA         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$ToastAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$Months     = 'jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'
$StateLabel = @{ InStock = 'AVAILABLE NOW'; Unverified = 'Unconfirmed (call store)'; PreOrder = 'Pre-order / backorder'; OutOfStock = 'Out of stock'; Error = 'Check failed' }

# Cloud mode (GitHub Actions, .github/workflows/check.yml): alert settings come from the TRACKER_SECRETS secret, there is
# no desktop for Windows alerts or opening store pages, and the saved log, health file and page are public, so tokens
# and phone numbers are masked in them.
$Cloud  = [bool]$env:GITHUB_ACTIONS
$RunUrl = ''
$PrivateValues = @()
if ($Cloud -and $env:GITHUB_REPOSITORY) {
    $repoParts    = $env:GITHUB_REPOSITORY.Split('/')
    $DashboardUrl = "https://$($repoParts[0].ToLowerInvariant()).github.io/$($repoParts[1])/"
    $RunUrl       = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/workflows/check.yml"
}

function Hide-Private([string]$Text) {
    if (-not $Cloud -or -not $Text) { return $Text }
    foreach ($v in $PrivateValues) { $Text = $Text.Replace($v, '***') }
    [regex]::Replace($Text, '\+?\d{9,}', '***')
}

function Write-Log([string]$Message) {
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) { Move-Item $LogPath "$LogPath.old" -Force }
    Add-Content -Path $LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), (Hide-Private $Message)) -Encoding UTF8
}

# The Twilio Auth Token is stored DPAPI-encrypted (twilioAuthTokenEncrypted): only this Windows account on this PC can
# decrypt it. A plain token pasted into twilioAuthToken is used as-is, then encrypted and cleared by Protect-ConfigToken.
function Unprotect-Secret([string]$Cipher) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $Cipher))
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Protect-ConfigSecrets {
    $path = Join-Path $Root 'config.json'
    $raw  = Get-Content $path -Raw -Encoding UTF8
    $nl   = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $done = @()
    foreach ($sf in $SecretFields) {
        $f = $sf[1]
        $m = [regex]::Match($raw, "`"$f`"\s*:\s*`"([^`"]+)`"")
        if (-not $m.Success) { continue }
        $cipher = ConvertTo-SecureString $m.Groups[1].Value -AsPlainText -Force | ConvertFrom-SecureString
        $raw = $raw.Remove($m.Index, $m.Length).Insert($m.Index, "`"$f`": `"`"")
        if ($raw -match "`"${f}Encrypted`"\s*:\s*`"[^`"]*`"") {
            $raw = [regex]::Replace($raw, "(`"${f}Encrypted`"\s*:\s*`")[^`"]*(`")", "`${1}$cipher`${2}")
        } else {
            $raw = $raw.Replace("`"$f`": `"`"", "`"$f`": `"`",$nl    `"${f}Encrypted`": `"$cipher`"")
        }
        $done += $f
    }
    if (-not $done) { return }
    $null = $raw | ConvertFrom-Json
    [IO.File]::WriteAllText($path, $raw, (New-Object Text.UTF8Encoding($false)))
    Write-Log "Encrypted in config.json: $($done -join ', ')"
}


function Get-Html([string]$Url) {
    (Invoke-WebRequest -Uri $Url -UserAgent $UA -UseBasicParsing -TimeoutSec 30 -Headers @{ 'Accept-Language' = 'en-US,en;q=0.9' }).Content
}

# Parses "Jan 22", "25 Jan", "Mon, 25 Jan onwards", "25th Jan'27"; year-less dates roll forward to the next occurrence.
function Get-EtaDate([string]$Text) {
    if (-not $Text) { return $null }
    $mon = ($Months -join '|')
    $m = [regex]::Match($Text, "(?<d>\d{1,2})(?:st|nd|rd|th)?\s+(?<m>$mon)[a-z]*(?:'(?<y>\d{2})|\s+(?<y>\d{4}))?", 'IgnoreCase')
    if (-not $m.Success) { $m = [regex]::Match($Text, "(?<m>$mon)[a-z]*\s+(?<d>\d{1,2})(?:,?\s+(?<y>\d{4}))?", 'IgnoreCase') }
    if (-not $m.Success) { return $null }
    $month = [array]::IndexOf($Months, $m.Groups['m'].Value.ToLower()) + 1
    $day   = [int]$m.Groups['d'].Value
    $today = (Get-Date).Date
    try {
        if ($m.Groups['y'].Success) {
            $year = [int]$m.Groups['y'].Value
            if ($year -lt 100) { $year += 2000 }
            return [datetime]::new($year, $month, $day)
        }
        $eta = [datetime]::new($today.Year, $month, $day)
        if ($eta -lt $today.AddDays(-1)) { $eta = $eta.AddYears(1) }
        return $eta
    } catch { return $null }
}

function Resolve-State([bool]$Orderable, $Eta, [bool]$PreorderHint) {
    if (-not $Orderable) { return 'OutOfStock' }
    # Orderable with a delivery date counts as available however far away the date is; the row gets a delivery note.
    if ($Eta) { return 'InStock' }
    if ($PreorderHint) { return 'PreOrder' }
    'InStock'
}

function Test-Apple($Target) {
    $part = [uri]::EscapeDataString($Target.part)
    $json = Invoke-RestMethod -Uri "https://www.apple.com/ae/shop/delivery-message?parts.0=$part&mts.0=regular" -UserAgent $UA -TimeoutSec 30
    $msg  = $json.body.content.deliveryMessage.($Target.part).regular
    if (-not $msg) { throw "Apple returned no delivery data for $($Target.part)" }
    $text = ($msg.deliveryOptionMessages | ForEach-Object { $_.displayName }) -join '; '
    if (-not $msg.isBuyable) { $text = 'Currently unavailable' }
    @{
        State  = Resolve-State ([bool]$msg.isBuyable) (Get-EtaDate $text) ($text -notmatch 'in stock|today|tomorrow')
        Detail = $text
    }
}

# Sharaf DG: finds every listing for the model via the site's public Algolia search (catches new non-pre-order pages),
# then asks Sharaf's own store-availability API which branches hold units (atp = available-to-promise).
function Test-SharafDGStock($Target) {
    $appId = '9KHJLG93J1'
    $key   = if ($Target.algoliaKey) { $Target.algoliaKey } else { 'e81d5b30a712bb28f0f1d2a52fc92dd0' }
    $body  = @{ params = 'hitsPerPage=50&query=' + [uri]::EscapeDataString($Target.query) } | ConvertTo-Json -Compress
    $res   = Invoke-RestMethod -Method Post -Uri "https://$appId-dsn.algolia.net/1/indexes/products_index/query" -TimeoutSec 30 `
                -Headers @{ 'X-Algolia-Application-Id' = $appId; 'X-Algolia-API-Key' = $key } -ContentType 'application/json' -Body $body
    if ($null -eq $res.hits) { throw 'Sharaf DG search returned no results (search key changed?)' }

    $hits = @($res.hits | Where-Object { $_.model_number -eq $Target.model -and $_.post_status -eq 'publish' })
    if (-not $hits) { return @{ State = 'OutOfStock'; Detail = 'No Sharaf DG listing for this model' } }

    $online = @($hits | Where-Object { "$($_.archive)" -eq '0' -and "$($_.in_stock)" -eq '1' -and [double]$_.price -gt 0 })
    $buyNow = @($online | Where-Object { $_.post_title -notmatch 'Pre-?order' })
    $preOrd = @($online | Where-Object { $_.post_title -match 'Pre-?order' })

    $branches  = New-Object System.Collections.Generic.SortedSet[string]
    $branchUrl = $null
    # Only active, priced, non-pre-order listings count: an archived listing (website shows "Out of Stock", no price)
    # still reports branch units, but they are held for pre-orders and can't be bought in store.
    foreach ($sku in @($buyNow | ForEach-Object { $_.main_sku } | Where-Object { $_ } | Select-Object -Unique)) {
        $stores = Invoke-RestMethod -Uri "https://uae.sharafdg.com/wp-json/sdg/v1/store?sku=$sku" -UserAgent $UA -TimeoutSec 30
        foreach ($s in @($stores)) {
            $atp = 0.0
            if ($s -and "$($s.active)" -eq '1' -and [double]::TryParse("$($s.atp)", [ref]$atp) -and $atp -gt 0) {
                [void]$branches.Add(($s.name -replace '\s+', ' ').Trim())
                if (-not $branchUrl) { $branchUrl = ($hits | Where-Object { $_.main_sku -eq $sku } | Select-Object -First 1).permalink }
            }
        }
    }

    $onlineText = if ($buyNow) { 'online: buy now' } elseif ($preOrd) { 'online: pre-order only' } else { 'online: out of stock' }
    # Branch names only (no unit counts) so routine sales don't trigger a change alert every few minutes.
    if ($branches.Count -or $buyNow) {
        $where = if ($branches.Count) { 'In store at ' + (@($branches) -join ', ') + ' (call ahead)' } else { 'Buy now online' }
        $url   = if ($buyNow) { $buyNow[0].permalink } else { $branchUrl }
        return @{ State = 'InStock'; Detail = "$where | $onlineText"; Url = $url }
    }
    if ($preOrd) { return @{ State = 'PreOrder'; Detail = "Pre-order online, no branch stock"; Url = $preOrd[0].permalink } }
    @{ State = 'OutOfStock'; Detail = 'Out of stock online and in all branches' }
}

# Jumbo: queries Jumbo's own catalog API, which returns every listing for the colour with live stock flags,
# including "Advance Payment" reservation listings that don't appear on the tracked product page.
function Test-JumboStock($Target) {
    $q   = $Target.query | ConvertTo-Json
    $req = '{"query":{"bool":{"must":[{"match":{"name":{"query":' + $q + ',"operator":"and"}}}]}}}'
    $url = 'https://www.jumbo.ae/api/catalog/magento_en/product/_search?size=30&_source_include=sku,name,url_path,final_price,stock,type_id,status,KeyProductFeatures&request=' +
           [uri]::EscapeDataString($req)
    $res = Invoke-RestMethod -Uri $url -UserAgent $UA -TimeoutSec 40
    if ($null -eq $res.hits.hits) { throw 'Jumbo catalog search returned no results list' }

    $items   = @($res.hits.hits | ForEach-Object { $_._source } |
                 Where-Object { "$($_.status)" -eq '1' -and $_.name -match [regex]::Escape($Target.colour) -and $_.name -match '512\s*GB' })
    $advance = @($items | Where-Object { $_.name -match 'Advance Payment' -or $_.type_id -eq 'virtual' })
    $phones  = @($items | Where-Object { $advance -notcontains $_ })
    $buyable = @($phones  | Where-Object { $_.stock.is_in_stock })
    $advOpen = @($advance | Where-Object { $_.stock.is_in_stock })
    if (-not $items) { return @{ State = 'OutOfStock'; Detail = 'No Jumbo listing for this colour' } }

    $lead = ''
    foreach ($p in $phones) {
        $m = [regex]::Match("$($p.KeyProductFeatures)", 'Delivery Lead Time:\s*([^;]+)')
        if ($m.Success) { $lead = $m.Groups[1].Value.Trim(); break }
    }
    $leadText = if ($lead) { " | delivery $lead" } else { '' }

    if ($buyable) {
        $b = $buyable[0]
        return @{ State = Resolve-State $true (Get-EtaDate $lead) $false; Detail = "In stock online$leadText"; Url = "https://www.jumbo.ae/$($b.url_path)" }
    }
    if ($advOpen) {
        $a = $advOpen[0]
        return @{ State = 'PreOrder'; Detail = "Reservation open: AED $([int]$a.final_price) advance payment$leadText"; Url = "https://www.jumbo.ae/$($a.url_path)" }
    }
    @{ State = 'OutOfStock'; Detail = "Out of stock online$leadText" }
}

function Test-Amazon($Target) {
    $html = Get-Html $Target.url
    if ($html -notmatch 's-search-result') { throw 'Search results not returned (captcha?)' }
    $titles = [regex]::Matches($html, '<h2[^>]*aria-label="([^"]+)"') |
        ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value).Trim() } |
        Where-Object { $_ -match '^(Apple\s+)?iPhone Duo\b' -and $_ -match '\b512\s?GB\b' -and
                       $_ -notmatch 'case|cover|protector|folio|glass|skin|handbuch|manual|guide|book|anleitung' } |
        Select-Object -Unique
    if ($titles) { return @{ State = 'InStock'; Detail = "Listed: $(@($titles)[0])" } }
    @{ State = 'OutOfStock'; Detail = 'No iPhone Duo 512GB listing' }
}

# Some stores stall Invoke-WebRequest, and stall curl too unless browser-style Sec-Fetch headers are sent.
# -Cookies is for sites that loop through cookie-setting redirects (du), which curl only follows with its cookie engine on.
function Get-CurlText([string]$Url, [switch]$Cookies) {
    $tmp = [IO.Path]::GetTempFileName()
    $jar = $null
    $cookieArgs = @()
    if ($Cookies) { $jar = [IO.Path]::GetTempFileName(); $cookieArgs = @('-b', $jar, '-c', $jar) }
    try {
        & curl.exe -s -L --compressed --max-time 40 @cookieArgs -o $tmp -H "User-Agent: $UA" `
            -H 'Accept: text/html,application/json,*/*;q=0.8' -H 'Accept-Language: en-US,en;q=0.9' `
            -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Site: none' -H 'Sec-Fetch-Dest: document' -H 'Upgrade-Insecure-Requests: 1' $Url
        if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }
        Get-Content $tmp -Raw -Encoding UTF8
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        if ($jar) { Remove-Item $jar -ErrorAction SilentlyContinue }
    }
}

# du's product page calls this endpoint on load to refresh stock; the server-rendered schema.org flag can lag.
function Test-Du($Target) {
    $raw = Get-CurlText ('https://shop.du.ae/async/product/getstocklevel?productCode=' + [uri]::EscapeDataString($Target.code)) -Cookies
    try { $stock = $raw | ConvertFrom-Json } catch { throw 'du stock API returned an unexpected page (blocked?)' }
    if ($null -eq $stock.cssClassForContainer) { throw 'du stock API response not recognised' }
    $msg = "$($stock.stockMessage)".Trim()
    if (-not $msg) { $msg = 'In stock' }
    $state = if ($stock.cssClassForContainer -eq 'error') { 'OutOfStock' } elseif ($msg -match 'pre-?order') { 'PreOrder' } else { 'InStock' }
    @{ State = $state; Detail = "$msg | outright or with a du plan" }
}

# e& renders full stock flags only for the SKU named in the URL, inside Angular's ng-state JSON.
function Test-EAnd($Target) {
    $html = Get-CurlText $Target.url
    $m = [regex]::Match($html, '<script id="ng-state" type="application/json">(.*?)</script>', 'Singleline')
    if (-not $m.Success) { throw 'e& page data not found (blocked or layout changed?)' }
    # ConvertFrom-Json rejects this JSON (it has keys differing only by case), so use the case-sensitive serializer.
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 200
    $stack = New-Object System.Collections.Stack
    $stack.Push($ser.DeserializeObject($m.Groups[1].Value))
    $sku = $null
    while ($stack.Count -and -not $sku) {
        $n = $stack.Pop()
        if ($n -is [System.Collections.IDictionary]) {
            if ($n['skuId'] -eq $Target.sku -and $n.ContainsKey('inStock')) { $sku = $n }
            else { foreach ($v in $n.Values) { $stack.Push($v) } }
        } elseif ($n -is [System.Array]) {
            foreach ($v in $n) { $stack.Push($v) }
        }
    }
    if (-not $sku) { throw "e& stock data for $($Target.sku) not found (page changed?)" }
    $plan = @($sku['paymentOptions']) | Where-Object { $_['type'] -eq 'SmartPay' } |
        Sort-Object { [int]$_['duration'] } -Descending | Select-Object -First 1
    $price = if ($plan) { " | SmartPay AED $([double]$plan['priceIncVAT'])/mo x $($plan['duration'])" } else { '' }
    if ($sku['inStock'] -or $sku['isInStockNonContract']) { return @{ State = 'InStock'; Detail = "In stock$price" } }
    if ($sku['isInStockContract']) { return @{ State = 'InStock'; Detail = "In stock with e& plan only$price" } }
    @{ State = 'OutOfStock'; Detail = "Out of stock$price" }
}

# First full-device price in the text (e.g. "AED 14,499", "9,349.00 AED"); skips monthly instalments and deposits.
function Get-Price([string]$Text) {
    if (-not $Text) { return $null }
    foreach ($rx in 'AED\s*(?<n>\d[\d,]*(?:\.\d+)?)(?![\d,.])(?!\s*/\s*mo)(?!\s*advance)', '(?<n>\d[\d,]*(?:\.\d+)?)(?![\d,.])\s*AED') {
        foreach ($m in [regex]::Matches($Text, $rx, 'IgnoreCase')) {
            $v = 0.0
            if ([double]::TryParse(($m.Groups['n'].Value -replace ',', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and $v -ge 3000) { return $v }
        }
    }
    $null
}

function Format-OverApple($Price) {
    if (-not $Price -or -not $Config.applePrice) { return '' }
    $diff = $Price - $Config.applePrice
    $pct  = [math]::Round(100 * $diff / $Config.applePrice)
    if ([math]::Abs($diff) -lt 1) { return "Apple's price (AED $('{0:N0}' -f $Config.applePrice))" }
    if ($diff -gt 0) { return "AED $('{0:N0}' -f $diff) (+$pct%) above Apple's AED $('{0:N0}' -f $Config.applePrice)" }
    "AED $('{0:N0}' -f -$diff) ($pct%) below Apple's AED $('{0:N0}' -f $Config.applePrice)"
}

function Test-Noon($Target) {
    $api  = 'https://www.noon.com/_svc/catalog/api/v3/u/search?limit=50&q=' + [uri]::EscapeDataString($Target.query)
    $json = Get-CurlText $api | ConvertFrom-Json
    if ($null -eq $json.hits) { throw 'Noon search API returned no results (blocked?)' }
    $phones = @($json.hits | Where-Object {
        $_.name -match 'iPhone Duo' -and $_.name -match '512\s*GB' -and
        $_.name -notmatch 'case|cover|protector|glass|charger|power bank|cable|skin|stand|mount|holder' })
    $buyable = @($phones | Where-Object { $_.is_buyable })
    if ($buyable) {
        $best  = $buyable | Sort-Object { if ($_.sale_price) { $_.sale_price } else { $_.price } } | Select-Object -First 1
        $price = if ($best.sale_price) { $best.sale_price } else { $best.price }
        return @{ State = 'InStock'; Detail = "$($buyable.Count) listing(s), from AED $price - $($best.name)"; Url = "https://www.noon.com/uae-en$($best.pdp_url)" }
    }
    if ($phones) { return @{ State = 'OutOfStock'; Detail = "Listed but not buyable: $($phones[0].name)" } }
    @{ State = 'OutOfStock'; Detail = 'No iPhone Duo 512GB listing' }
}

# Apple's newer fulfillment-messages endpoint is bot-blocked (HTTP 541); the older retail/pickup-message one still answers curl.
function Test-ApplePickup($Target) {
    $part = [uri]::EscapeDataString($Target.part)
    $loc  = [uri]::EscapeDataString($Target.location)
    $raw  = Get-CurlText "https://www.apple.com/ae/shop/retail/pickup-message?pl=true&parts.0=$part&location=$loc"
    # The response has keys that differ only by case, which ConvertFrom-Json rejects.
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 20MB
    try { $json = $ser.DeserializeObject($raw) } catch { throw 'Apple pickup returned non-JSON (blocked?)' }
    $stores = $json['body']['stores']
    if (-not $stores) { throw 'Apple pickup returned no stores' }
    $byQuote = [ordered]@{}
    $open = @()
    foreach ($s in $stores) {
        $pa = $s['partsAvailability'][$Target.part]
        if (-not $pa) { continue }
        $quote = $pa['pickupSearchQuote']
        if ($pa['messageTypes'] -and $pa['messageTypes']['regular'] -and $pa['messageTypes']['regular']['storePickupQuote']) {
            $quote = $pa['messageTypes']['regular']['storePickupQuote']
        }
        $quote = ($quote -replace '\s+at Apple .*$', '').Trim()
        if (-not $quote) { $quote = $pa['pickupDisplay'] }
        if (-not $byQuote.Contains($quote)) { $byQuote[$quote] = @() }
        $byQuote[$quote] += $s['storeName']
        if ($pa['pickupDisplay'] -eq 'available') { $open += $s['storeName'] }
    }
    if (-not $byQuote.Count) { throw "Apple pickup has no data for $($Target.part)" }
    $detail = ($byQuote.Keys | ForEach-Object { '{0}: {1}' -f $_, ($byQuote[$_] -join ', ') }) -join ' | '
    @{ State = $(if ($open) { 'InStock' } else { 'OutOfStock' }); Detail = $detail }
}

# Virgin's category pages render products with JavaScript; its search-suggestion endpoint returns them as JSON.
function Test-Virgin($Target) {
    $json = Get-CurlText ('https://www.virginmegastore.ae/en/search/autocomplete/SearchBox?term=' + [uri]::EscapeDataString($Target.query)) | ConvertFrom-Json
    if ($null -eq $json.products) { throw 'Virgin search returned no product list (blocked?)' }
    $phones = @($json.products | Where-Object {
        $_.name -match 'iPhone Duo' -and $_.name -match '512\s*GB' -and
        $_.name -notmatch 'case|cover|protector|glass|charger|cable|skin|stand|holder|lens' })
    if (-not $phones) { return @{ State = 'OutOfStock'; Detail = 'No iPhone Duo 512GB listing' } }

    $rank = @{ InStock = 0; PreOrder = 1; OutOfStock = 2 }
    $found = foreach ($p in $phones) {
        $url   = 'https://www.virginmegastore.ae/en' + $p.url
        $avail = [regex]::Match((Get-CurlText $url), '"availability"\s*:\s*"https?://schema\.org/(\w+)"').Groups[1].Value
        $state = switch -Regex ($avail) {
            'InStock|LimitedAvailability|OnlineOnly' { 'InStock' }
            'OutOfStock|SoldOut|Discontinued'        { 'OutOfStock' }
            default                                  { 'PreOrder' }
        }
        $note = if ($avail) { $avail } else { 'listed, stock not shown' }
        [pscustomobject]@{ State = $state; Url = $url; Text = "$($p.name) ($($p.price.formattedValueWithCurrency)): $note" }
    }
    $best = $found | Sort-Object { $rank[$_.State] } | Select-Object -First 1
    @{ State = $best.State; Detail = ($found | ForEach-Object Text) -join ' | '; Url = $best.Url }
}

# iStyle (Apple Premium Reseller, Shopify): one product per part number; .js exposes `available` (inventory tracked).
function Test-IStyle($Target) {
    $inStock = @(); $parts = @()
    foreach ($h in $Target.handles) {
        $p = Get-Html "https://istyle.ae/products/$h.js" | ConvertFrom-Json
        if (-not $p.variants) { throw "iStyle returned no product data for $h" }
        $name = $p.title -replace '^iPhone Duo\s*', ''
        $price = '{0:N0}' -f ($p.price / 100)
        if ($p.available) { $inStock += @{ Name = $name; Price = $price; Url = "https://istyle.ae/products/$h" } }
        $parts += "${name}: " + $(if ($p.available) { "in stock (AED $price)" } else { 'sold out' })
    }
    if ($inStock) {
        return @{ State = 'InStock'; Detail = 'Online: ' + ($parts -join '; '); Url = $inStock[0].Url }
    }
    @{ State = 'OutOfStock'; Detail = $parts -join '; ' }
}

# iPoint (independent reseller, Shopify): one "iPHONE DUO" product with storage variants; no colour option, priced well above Apple.
function Test-IPoint($Target) {
    $p = Get-Html "https://ipoint.ae/products/$($Target.handle).js" | ConvertFrom-Json
    $v = $p.variants | Where-Object { $_.title -match '^\s*512' } | Select-Object -First 1
    if (-not $v) { throw 'iPoint product has no 512GB variant (listing changed?)' }
    $price = '{0:N0}' -f ($v.price / 100)
    if ($v.available) {
        return @{ State = 'InStock'; Detail = "512GB in stock at AED $price (reseller price; colour not listed)"; Url = "https://ipoint.ae/products/$($Target.handle)?variant=$($v.id)" }
    }
    @{ State = 'OutOfStock'; Detail = "512GB sold out (AED $price)" }
}

# Microless: search result cards carry stock (`product-unavailable` = out of stock), delivery date and store-pickup flag.
function Test-Microless($Target) {
    $html = Get-Html $Target.url
    if ($html -notmatch 'id="search-results-products"') { throw 'Search results not found (blocked or layout changed?)' }
    $cards = [regex]::Matches($html, '<div data-prodid="\d+"[^>]*class="product product-carousel[\s\S]*?(?=<div data-prodid="\d+"|<div class="pagination|$)') |
        ForEach-Object { $_.Value } |
        Where-Object { $_ -match 'iPhone Duo' -and $_ -match '512GB' }
    if (-not $cards) { return @{ State = 'OutOfStock'; Detail = 'No iPhone Duo 512GB listing' } }
    $avail = @(); $soldOut = 0; $eta = $null
    foreach ($c in $cards) {
        $title = [Net.WebUtility]::HtmlDecode([regex]::Match($c, 'class="product-title">\s*<a[^>]*>\s*([^<]+?)\s*</a>').Groups[1].Value)
        $short = [regex]::Match($title, '512GB Storage,\s*([^|]+?)\s*(\||$)').Groups[1].Value
        if (-not $short) { $short = $title }
        if ($c -match 'product-unavailable|Currently Unavailable') { $soldOut++; continue }
        $plain = ([Net.WebUtility]::HtmlDecode(($c -replace '<[^>]+>', ' ')) -replace '\s+', ' ')
        $price = [regex]::Match($c, 'price-amount[^>]*>\s*([\d,\.]+)').Groups[1].Value
        $by    = [regex]::Match($plain, 'Delivered by\s+([A-Za-z]{3,9}\s+\d{1,2})', 'IgnoreCase').Groups[1].Value
        $d = Get-EtaDate $by
        if ($d -and (-not $eta -or $d -lt $eta)) { $eta = $d }
        $bits = @($short)
        if ($price) { $bits += "AED $price" }
        if ($by)    { $bits += "delivered by $by" }
        if ($plain -match 'Free store pickup') { $bits += 'free store pickup' }
        $url = [regex]::Match($c, 'href="(https://uae\.microless\.com/product/[^"]+)"').Groups[1].Value
        $avail += @{ Text = $bits -join ', '; Url = $url }
    }
    if ($avail) {
        $texts = @($avail | ForEach-Object { $_.Text } | Select-Object -Unique)
        $detail = ($texts | Select-Object -First 4) -join '; '
        if ($texts.Count -gt 4) { $detail += " (+$($texts.Count - 4) more)" }
        return @{ State = Resolve-State $true $eta $false; Detail = $detail; Url = $avail[0].Url }
    }
    @{ State = 'OutOfStock'; Detail = "$soldOut listing(s), all Currently Unavailable (international versions)" }
}

# Carrefour UAE: the search page is server-rendered and embeds per-product JSON (stock, productId, productName, sellingPrice).
# Needs Get-CurlText; Invoke-WebRequest gets an empty 53-byte response. Online stock only (no per-branch data exposed).
function Test-Carrefour($Target) {
    $html = Get-CurlText ('https://www.carrefouruae.com/mafuae/en/search?keyword=' + [uri]::EscapeDataString($Target.query))
    if ($html -notmatch '<title>[^<]*Carrefour UAE</title>') { throw 'Search page not recognised (blocked?)' }
    $rx = '\\"stockLevelStatus\\":\\"(?<lvl>\w+)\\"\}(?:(?!stockLevelStatus).){0,1500}?\\"productId\\":\\"(?<id>\d+)\\",\\"productName\\":\\"(?<name>[^"\\]+)\\"(?:(?!stockLevelStatus).){0,1500}?\\"sellingPrice\\":(?<price>[\d.]+)'
    $qtyRx = '\\"stock\\":\{\\"value\\":(?<qty>\d+),'
    $items = foreach ($m in [regex]::Matches($html, $rx)) {
        $name = $m.Groups['name'].Value -replace '\s+', ' '
        if ($name -notmatch 'iPhone Duo' -or $name -notmatch '512\s*GB' -or $name -match 'case|cover|protector|glass|charger|cable|skin') { continue }
        $qty = [regex]::Match($html.Substring([Math]::Max(0, $m.Index - 60), 60), $qtyRx).Groups['qty'].Value
        $id  = $m.Groups['id'].Value
        $href = [regex]::Match($html, "href=""(/mafuae/en/[^""]+/p/$id[^""]*)""").Groups[1].Value
        [pscustomobject]@{
            Name     = $name
            Price    = [decimal]$m.Groups['price'].Value
            Level    = $m.Groups['lvl'].Value
            Buyable  = ($m.Groups['lvl'].Value -notmatch 'outOfStock') -and ($qty -ne '0')
            Url      = if ($href) { 'https://www.carrefouruae.com' + [Net.WebUtility]::HtmlDecode($href) } else { $null }
        }
    }
    $buyable = @($items | Where-Object Buyable | Sort-Object Price)
    if ($buyable) {
        $best = $buyable[0]
        return @{ State = 'InStock'; Detail = "$($buyable.Count) listing(s), from AED $($best.Price) - $($best.Name) ($($best.Level))"; Url = $best.Url }
    }
    if ($items) { return @{ State = 'OutOfStock'; Detail = "Listed but out of stock: $(@($items)[0].Name)" } }
    @{ State = 'OutOfStock'; Detail = 'No iPhone Duo 512GB listing' }
}

# Lulu (Akinon storefront): /list/?search_text= is server-rendered with product JSON (pk, name, price, in_stock, absolute_url, stock).
# Invoke-WebRequest gets 403; Get-CurlText works. Pre-orders are marked only in the product URL slug ("pre-order-...").
function Test-Lulu($Target) {
    $html = Get-CurlText ('https://www.luluhypermarket.com/en-ae/list/?search_text=' + [uri]::EscapeDataString($Target.query))
    if ($html -notmatch 'akinoncloud') { throw 'Lulu page not recognised (blocked?)' }
    $starts = [regex]::Matches($html, '\\"pk\\":\\"\d+\\",\\"name\\":\\"(?<name>[^"\\]+)\\"')
    $tails  = [regex]::Matches($html, '\\"price\\":\\"(?<price>[\d.]+)\\",\\"in_stock\\":(?<instock>\w+),.{0,400}?\\"absolute_url\\":\\"(?<url>[^"\\]+)\\".{0,800}?\\"stock\\":\\"(?<stock>[\d.]+)\\"')
    $items = foreach ($t in $tails) {
        $start = $starts | Where-Object { $_.Index -lt $t.Index } | Select-Object -Last 1
        if (-not $start) { continue }
        $name = $start.Groups['name'].Value -replace '\s+', ' '
        if ($name -notmatch 'iPhone Duo' -or $name -notmatch '512\s*GB' -or $name -match 'case|cover|protector|glass|charger|cable|skin|bundle') { continue }
        $url = $t.Groups['url'].Value
        [pscustomobject]@{
            Name      = $name
            Price     = [decimal]$t.Groups['price'].Value
            Orderable = ($t.Groups['instock'].Value -eq 'true') -and ([decimal]$t.Groups['stock'].Value -gt 0)
            PreOrder  = ($url -match 'pre-?order') -or ($name -match 'pre-?order')
            Url       = 'https://www.luluhypermarket.com/en-ae' + $url
        }
    }
    $orderable = @($items | Where-Object Orderable | Sort-Object PreOrder, Price)
    if ($orderable) {
        $best  = $orderable[0]
        $label = if ($best.PreOrder) { 'Pre-order' } else { 'In stock' }
        return @{
            State  = Resolve-State $true $null $best.PreOrder
            Detail = "$label - $($orderable.Count) listing(s), from AED $($best.Price.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)) - $($best.Name)"
            Url    = $best.Url
        }
    }
    if ($items) { return @{ State = 'OutOfStock'; Detail = "Listed but out of stock: $(@($items)[0].Name)" } }
    @{ State = 'OutOfStock'; Detail = 'No iPhone Duo 512GB listing' }
}

# Dubai Duty Free: Oracle Commerce search API.
function Test-DubaiDutyFree($Target) {
    $api  = 'https://www.dubaidutyfree.com/ccstore/v1/search?Nrpp=50&Ntt=' + [uri]::EscapeDataString($Target.query)
    $json = Get-CurlText $api | ConvertFrom-Json
    if ($null -eq $json.resultsList) { throw 'Dubai Duty Free search API returned no results list (blocked?)' }
    $skus = @($json.resultsList.records | ForEach-Object { $_.records } | ForEach-Object { $_.attributes })
    $phones = @($skus | Where-Object {
        $n = @($_.'product.displayName')[0]
        $n -match 'iPhone Duo' -and $n -match '512\s*GB' -and
        $n -notmatch 'case|cover|folio|protector|glass|charger|cable|skin|stand|mount|holder|lens' })
    $orderable = @($phones | Where-Object { @($_.'sku.availabilityStatus')[0] -match '^(INSTOCK|PREORDERABLE|BACKORDERABLE)$' })
    if ($orderable) {
        $best  = $orderable | Sort-Object { [double]@($_.'sku.activePrice')[0] } | Select-Object -First 1
        $state = if (@($best.'sku.availabilityStatus')[0] -eq 'INSTOCK') { 'InStock' } else { 'PreOrder' }
        return @{
            State  = $state
            Detail = "$($orderable.Count) listing(s), from AED $([double]@($best.'sku.activePrice')[0]) - $(@($best.'product.displayName')[0])"
            Url    = 'https://www.dubaidutyfree.com' + @($best.'product.route')[0]
        }
    }
    if ($phones) { return @{ State = 'OutOfStock'; Detail = "Listed but out of stock: $(@($phones[0].'product.displayName')[0])" } }
    @{ State = 'OutOfStock'; Detail = 'No iPhone Duo 512GB listing' }
}

# Grand Stores: Magento product page; schema.org availability matches the visible "In stock" label.
function Test-GrandStores($Target) {
    $html = Get-Html $Target.url
    if ($html -notmatch 'iPhone Duo') { throw 'Page did not load the product (blocked or moved?)' }
    $avail = [regex]::Match($html, '"availability"\s*:\s*"https?://schema\.org/(\w+)"').Groups[1].Value
    if (-not $avail) { throw 'Stock marker not found (page layout changed?)' }
    $price     = [regex]::Match($html, 'product:price:amount" content="([\d.]+)"').Groups[1].Value
    $orderable = $avail -match 'InStock|PreOrder|BackOrder|LimitedAvailability'
    $detail    = if ($orderable) { $avail } else { 'Out of stock' }
    if ($price) { $detail += " | AED $([double]$price)" }
    @{ State = Resolve-State $orderable $null ($avail -match 'PreOrder|BackOrder'); Detail = $detail }
}

# Cartlow: marketplace JSON API (mostly refurbished); only "Brand New" listings count. is_saleable is the stock flag;
# quantity_message says "Stock is not available." on every item and is ignored.
function Test-Cartlow($Target) {
    $api  = 'https://cartlow.com/api/products?query=' + [uri]::EscapeDataString($Target.query)
    $json = Get-CurlText $api | ConvertFrom-Json
    if ($null -eq $json.data) { throw 'Cartlow product API returned no data (blocked?)' }
    $phones = @($json.data | Where-Object {
        $_.name -match 'iPhone Duo' -and $_.name -match '512\s*GB' -and $_.condition_name -eq 'Brand New' -and
        $_.name -notmatch 'case|cover|protector|glass|charger|cable|skin|stand|mount|holder' })
    $buyable = @($phones | Where-Object { $_.is_saleable })
    if ($buyable) {
        $best = $buyable | Sort-Object { [double]($_.min_price -replace '[^\d.]', '') } | Select-Object -First 1
        return @{ State = 'InStock'; Detail = "$($buyable.Count) new listing(s), from $($best.min_price) - $($best.name)"; Url = "https://cartlow.com$($best.pdp_url)" }
    }
    if ($phones) { return @{ State = 'OutOfStock'; Detail = "Listed but not buyable: $($phones[0].name)" } }
    @{ State = 'OutOfStock'; Detail = 'No new iPhone Duo 512GB listing' }
}

# Revibe: Shopify store selling mostly refurbished phones; only variants whose Condition option is exactly "New" count.
function Test-Revibe($Target) {
    $suggest = Get-Html ('https://revibe.me/search/suggest.json?resources[type]=product&resources[limit]=10&q=' + [uri]::EscapeDataString($Target.query)) | ConvertFrom-Json
    if ($null -eq $suggest.resources) { throw 'Revibe search returned no results (blocked?)' }
    $new = @()
    foreach ($p in @($suggest.resources.results.products | Where-Object { $_.title -match 'iPhone Duo' })) {
        $pj = Get-Html "https://revibe.me/products/$($p.handle).js" | ConvertFrom-Json
        $new += @($pj.variants | Where-Object { $_.title -match '512\s*GB' -and @($_.options) -contains 'New' } | ForEach-Object {
            [pscustomobject]@{ Title = "$($pj.title) $($_.title)"; Available = [bool]$_.available; Price = $_.price / 100; Url = "https://revibe.me/products/$($pj.handle)?variant=$($_.id)" } })
    }
    $buyable = @($new | Where-Object Available)
    if ($buyable) {
        $best = $buyable | Sort-Object Price | Select-Object -First 1
        return @{ State = 'InStock'; Detail = "$($buyable.Count) new variant(s), from AED $($best.Price) - $($best.Title)"; Url = $best.Url }
    }
    if ($new) { return @{ State = 'OutOfStock'; Detail = "New 512GB listed but sold out: $($new[0].Title)" } }
    @{ State = 'OutOfStock'; Detail = 'No new iPhone Duo 512GB listing' }
}

# Noon Minutes (15-minute delivery) stocks its own dark-store catalog; the search page embeds it as seroval (not JSON),
# with camelCase fields following each isBuyable flag. Its products carry no page URL, so alerts link to the search page.
function Test-NoonMinutes($Target) {
    $html = Get-CurlText ('https://minutes.noon.com/uae-en/search/?q=' + [uri]::EscapeDataString($Target.query))
    if ($html -notmatch 'noon Minutes') { throw 'Noon Minutes page did not load (blocked?)' }
    # Sold-out items get the placeholder title "Dropping again soon"; their image alt text keeps the real name.
    $altBySku = @{}
    foreach ($m in [regex]::Matches($html, '<img alt="([^"]+)"[^>]*?(?:src|srcSet)="[^"]*?pzsku/([A-Z0-9]+)/')) {
        if (-not $altBySku.ContainsKey($m.Groups[2].Value)) { $altBySku[$m.Groups[2].Value] = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    }
    $phones = foreach ($seg in ($html -csplit 'isBuyable:' | Select-Object -Skip 1)) {
        $sku   = [regex]::Match($seg, '[,{]sku:"([A-Z0-9]+)').Groups[1].Value
        $title = [regex]::Match($seg, '[,{]title:"([^"]+)"').Groups[1].Value
        if ($sku -and $altBySku[$sku]) { $title = $altBySku[$sku] }
        $main  = ($title -split '\+')[0]
        if ($main -notmatch 'iPhone Duo' -or $main -notmatch '512\s*GB' -or
            $main -match 'case|cover|protector|glass|charger|power bank|cable|skin|stand|mount|holder') { continue }
        $price = [regex]::Match($seg, '[,{]offerPrice:([\d\.]+)').Groups[1].Value
        [pscustomobject]@{
            Title   = $title
            Buyable = $seg.StartsWith('!0')
            Price   = $(if ($price) { [double]$price } else { [double]::MaxValue })
        }
    }
    $buyable = @($phones | Where-Object Buyable)
    if ($buyable) {
        $best = $buyable | Sort-Object Price | Select-Object -First 1
        return @{ State = 'InStock'; Detail = "15-min delivery: $($buyable.Count) listing(s), from AED $($best.Price) - $($best.Title)" }
    }
    if ($phones) {
        $first = @($phones)[0]
        return @{ State = 'OutOfStock'; Detail = "Sold out, restock coming: $($first.Title) (AED $($first.Price))" }
    }
    @{ State = 'OutOfStock'; Detail = 'No iPhone Duo 512GB listing' }
}

function Show-Toast([string]$Title, [string]$Body, [string]$Url, [switch]$Urgent) {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $esc = [Security.SecurityElement]
    $scenario = if ($Urgent) { ' scenario="reminder"' } else { '' }
    $sound    = if ($Urgent) { 'ms-winsoundevent:Notification.Reminder' } else { 'ms-winsoundevent:Notification.Default' }
    $xml = @"
<toast activationType="protocol" launch="$($esc::Escape($Url))"$scenario>
  <visual><binding template="ToastGeneric"><text>$($esc::Escape($Title))</text><text>$($esc::Escape($Body))</text></binding></visual>
  <actions>
    <action content="Open store" activationType="protocol" arguments="$($esc::Escape($Url))"/>
    <action content="Dismiss" activationType="system" arguments="dismiss"/>
  </actions>
  <audio src="$sound"/>
</toast>
"@
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show([Windows.UI.Notifications.ToastNotification]::new($doc))
}

# Telegram template (HTML): bold title, store/model/status/price/details lines, timestamp, and a tap-to-open store button.
function Send-Telegram([string]$Title, [string]$Body, [string]$Url, $Row, [switch]$Silent) {
    $tg = $Config.telegram
    if (-not $tg.botToken -or -not $tg.chatId) { return $false }
    $h = { param($s) [Net.WebUtility]::HtmlEncode("$s") }
    $lines = @("<b>$(& $h $Title)</b>")
    if ($Row) {
        $lines += "<b>Store:</b> $(& $h $Row.Store)"
        $lines += "<b>Model:</b> iPhone Duo $(& $h $Row.Variant)"
        $lines += "<b>Status:</b> $(& $h $StateLabel[$Row.State])"
        if ($Row.Price) { $lines += "<b>Price:</b> $(& $h (('AED {0:N0}' -f [double]$Row.Price) + $(if ($Row.Vs) { " $([char]0xB7) $($Row.Vs)" })))" }
        if ($Row.Detail) { $lines += "<b>Details:</b> $(& $h $Row.Detail)" }
    } elseif ($Body) { $lines += (& $h $Body) }
    $lines += "<i>$(Get-Date -Format 'ddd d MMM, HH:mm')</i>"
    $msg = @{ chat_id = $tg.chatId; text = ($lines -join "`n"); parse_mode = 'HTML'; disable_web_page_preview = $true; disable_notification = [bool]$Silent }
    if ($Url -match '^https?://') {
        $label = if ($Row -and $Row.State -eq 'InStock') { 'Buy now' } else { 'Open store' }
        $msg.reply_markup = @{ inline_keyboard = @(, @(@{ text = $label; url = $Url })) }
    }
    $json = $msg | ConvertTo-Json -Depth 6 -Compress
    Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($tg.botToken)/sendMessage" -TimeoutSec 20 `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
    $true
}

# -Silent: Telegram delivers it without a notification sound (used for "gone out of stock").
function Send-Alert([string]$Title, [string]$Body, [string]$Url, [switch]$Urgent, $Row, [switch]$Silent) {
    if (-not $Cloud) {
        try { Show-Toast $Title $Body $Url -Urgent:$Urgent; Write-Log "Toast shown: $Title" }
        catch { Write-Log "Toast failed: $($_.Exception.Message)" }
    }
    try { if (Send-Telegram $Title $Body $Url $Row -Silent:$Silent) { Write-Log "Telegram sent$(if ($Silent) { ' (silent)' }): $Title" } }
    catch { Write-Log "Telegram failed: $($_.Exception.Message)" }
    if ($Urgent) {
        try { if (Send-WhatsApp "*$Title*`n$Body`n$Url" $Row) { Write-Log "WhatsApp sent: $Title" } }
        catch { Write-Log "WhatsApp failed: $(Get-ErrorText $_)"; Show-HealthAlert 'WhatsApp alert could not be sent' (Get-ErrorText $_) }
    }
}

# Phone call through Twilio's REST API; does nothing until the Twilio details are filled in config.json.
function Send-PhoneCall([string]$Message) {
    $pc = $Config.phoneCall
    if (-not $pc -or -not $pc.to -or -not $pc.twilioAccountSid -or -not $pc.twilioAuthToken -or -not $pc.twilioFrom) { return $false }
    # Trial accounts reject inline TwiML and most call options; a Twimlets URL that speaks the message (twice) is accepted.
    $spoken = [uri]::EscapeDataString($Message)
    $url    = "https://twimlets.com/message?Message%5B0%5D=$spoken&Message%5B1%5D=$spoken"
    Invoke-RestMethod -Method Post -Uri "https://api.twilio.com/2010-04-01/Accounts/$($pc.twilioAccountSid)/Calls.json" -TimeoutSec 30 `
        -Headers @{ Authorization = (Get-TwilioAuth) } -Body @{ To = $pc.to; From = $pc.twilioFrom; Url = $url } | Out-Null
    $true
}

# Twilio puts the useful reason in the response body; the exception text is only "(400) Bad Request".
function Get-ErrorText($ErrorRecord) {
    $text = if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $ErrorRecord.ErrorDetails.Message } else { $ErrorRecord.Exception.Message }
    Hide-Private $text
}

function Get-TwilioAuth {
    $pc = $Config.phoneCall
    'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($pc.twilioAccountSid):$($pc.twilioAuthToken)"))
}

# Your own approved WhatsApp template through Meta's Cloud API: {{1}} product, {{2}} store, {{3}} price, {{4}} link.
function Send-MetaTemplate($Row) {
    $wa = $Config.whatsapp
    if (-not $Row) { $Row = [pscustomobject]@{ Variant = '512GB (TEST)'; Store = 'Tracker test'; Price = $Config.applePrice; Url = 'https://www.apple.com/ae/shop/buy-iphone/iphone-duo' } }
    $price = if ($Row.Price) { 'AED {0:N0}' -f [double]$Row.Price } else { 'see the store page' }
    # Template parameters may not contain line breaks and are kept short.
    $vars  = @("iPhone Duo $($Row.Variant)", $Row.Store, $price, $Row.Url) | ForEach-Object {
        $v = ("$_" -replace '\s+', ' ').Trim(); if ($v.Length -gt 300) { $v.Substring(0, 300) } else { $v } }
    $lang  = if ($wa.metaLanguage) { $wa.metaLanguage } else { 'en' }
    $body  = @{ messaging_product = 'whatsapp'; to = ($wa.phone -replace '[^\d]', ''); type = 'template'
                template = @{ name = $wa.metaTemplate; language = @{ code = $lang }
                              components = @(@{ type = 'body'; parameters = @($vars | ForEach-Object { @{ type = 'text'; text = $_ } }) }) } } |
             ConvertTo-Json -Depth 8 -Compress
    Invoke-RestMethod -Method Post -Uri "https://graph.facebook.com/v21.0/$($wa.metaPhoneNumberId)/messages" -TimeoutSec 30 `
        -Headers @{ Authorization = "Bearer $($wa.metaToken)" } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}

# WhatsApp: Meta template first (if set up), otherwise Twilio (sandbox/trial: send "join twilio-trial" from WhatsApp first).
function Send-WhatsApp([string]$Text, $Row) {
    $wa = $Config.whatsapp
    $pc = $Config.phoneCall
    if ($wa -and $wa.phone -and $wa.metaPhoneNumberId -and $wa.metaToken -and $wa.metaTemplate) {
        try { Send-MetaTemplate $Row; return $true }
        catch { if (-not $wa.twilioFrom) { throw }; Write-Log "Meta WhatsApp failed, using Twilio instead: $(Get-ErrorText $_)" }
    }
    if (-not ($wa -and $wa.phone -and $wa.twilioFrom -and $pc.twilioAccountSid -and $pc.twilioAuthToken)) { return $false }
    $uri  = "https://api.twilio.com/2010-04-01/Accounts/$($pc.twilioAccountSid)/Messages.json"
    $base = @{ To = "whatsapp:$($wa.phone)"; From = "whatsapp:$($wa.twilioFrom)" }
    try {
        Invoke-RestMethod -Method Post -Uri $uri -TimeoutSec 30 -Headers @{ Authorization = (Get-TwilioAuth) } -Body ($base + @{ Body = $Text }) | Out-Null
    } catch {
        # Trial accounts refuse free text (error 21654) and only send their fixed template, so that arrives as a ping.
        if (-not $wa.twilioContentSid -or (Get-ErrorText $_) -notmatch '21654|ContentSid') { throw }
        Invoke-RestMethod -Method Post -Uri $uri -TimeoutSec 30 -Headers @{ Authorization = (Get-TwilioAuth) } -Body ($base + @{ ContentSid = $wa.twilioContentSid }) | Out-Null
    }
    $true
}

# Extra actions when a priority store gets confirmed stock: call the phone and open the store page so paying takes a minute.
function Invoke-PriorityActions($Row) {
    try { if (Send-PhoneCall "iPhone Duo 512 gigabyte is in stock at $($Row.Store). $($Row.Variant). Check your computer now.") { Write-Log "Phone call placed: $($Row.Store)" } }
    catch { Write-Log "Phone call failed: $(Get-ErrorText $_)"; Show-HealthAlert "Phone call to you failed ($($Row.Store) has stock!)" (Get-ErrorText $_) }
    if ($Config.autoOpenStorePage -and $Row.Url -match '^https?://') {
        try { Start-Process $Row.Url; Write-Log "Opened store page: $($Row.Url)" }
        catch { Write-Log "Opening store page failed: $($_.Exception.Message)" }
    }
}

function Add-History($Row, $From) {
    [void]$history.Add([ordered]@{ time = (Get-Date).ToString('o'); store = $Row.Store; variant = $Row.Variant; from = $From; to = $Row.State; detail = $Row.Detail })
}

# Self-check state survives between runs in health.json: failure streaks per store, Twilio status, pauses and crashes.
function Read-Health {
    $h = @{ stores = @{}; twilio = @{}; channels = @{}; lastRunAt = $null; pauses = @(); crashes = 0; crashAlertAt = $null; lastAlerts = @{} }
    if (-not (Test-Path $HealthPath)) { return $h }
    try { $j = Get-Content $HealthPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $h }
    if ($j.stores) {
        foreach ($p in $j.stores.PSObject.Properties) {
            $h.stores[$p.Name] = @{ fails = [int]$p.Value.fails; since = $p.Value.since; error = $p.Value.error; alerted = [bool]$p.Value.alerted }
        }
    }
    if ($j.twilio) { $h.twilio = @{ checkedAt = $j.twilio.checkedAt; ok = $j.twilio.ok; error = $j.twilio.error; alerted = [bool]$j.twilio.alerted } }
    if ($j.channels) {
        foreach ($p in $j.channels.PSObject.Properties) {
            $h.channels[$p.Name] = @{ checkedAt = $p.Value.checkedAt; ok = $p.Value.ok; error = $p.Value.error; alerted = [bool]$p.Value.alerted }
        }
    }
    $h.lastRunAt = $j.lastRunAt; $h.pauses = @($j.pauses | Where-Object { $_ }); $h.crashes = [int]$j.crashes; $h.crashAlertAt = $j.crashAlertAt
    if ($j.lastAlerts) { foreach ($p in $j.lastAlerts.PSObject.Properties) { $h.lastAlerts[$p.Name] = $p.Value } }
    $h
}

function Save-Health { $health | ConvertTo-Json -Depth 5 | Set-Content -Path $HealthPath -Encoding UTF8 }

# Problems with the tracker itself: Windows alert (opens the dashboard) plus Telegram if set up; never WhatsApp or a call.
function Show-HealthAlert([string]$Title, [string]$Body) {
    Write-Log "Self-check alert: $Title - $Body"
    if (-not $Cloud) {
        try { Show-Toast $Title $Body $DashboardUrl } catch { Write-Log "Self-check alert failed: $($_.Exception.Message)" }
    }
    try { [void](Send-Telegram $Title $Body) } catch { }
}

function Update-StoreHealth($Results) {
    $notes = New-Object System.Collections.ArrayList
    $failAfter = if ($Config.alertAfterFailedChecks) { [int]$Config.alertAfterFailedChecks } else { 5 }
    $seen = @{}
    foreach ($r in $Results) {
        $seen[$r.Key] = $true
        if ($r.Skipped) { continue }   # not checked this run: its failure streak stands as it was
        $s = $health.stores[$r.Key]
        if ($r.State -eq 'Error') {
            if (-not $s) { $s = @{ fails = 0; since = (Get-Date).ToString('o'); error = ''; alerted = $false }; $health.stores[$r.Key] = $s }
            $s.fails++; $s.error = $r.Detail
            if ($s.fails -ge $failAfter -and -not $s.alerted) {
                [void]$notes.Add(@{ Title = "Tracker can't check $($r.Store)"; Body = ("$($r.Variant) has failed $($s.fails) checks in a row since {0:HH:mm}: $($r.Detail)" -f [datetime]$s.since) })
                $s.alerted = $true
            }
        } elseif ($s) {
            if ($s.alerted) { [void]$notes.Add(@{ Title = "Tracker can check $($r.Store) again"; Body = "$($r.Variant) is being checked normally." }) }
            $health.stores.Remove($r.Key)
        }
    }
    foreach ($k in @($health.stores.Keys)) { if (-not $seen.ContainsKey($k)) { $health.stores.Remove($k) } }
    # One message per store, even when both colours fail (or recover) in the same run.
    foreach ($g in @($notes | Group-Object { $_.Title })) { Show-HealthAlert $g.Name (@($g.Group | ForEach-Object { $_.Body }) -join "`n") }
}

# Read-only credential check for Meta / Telegram every 6 hours (re-checked every run while broken).
function Test-ChannelHealth([string]$Name, [scriptblock]$Probe) {
    $c = $health.channels[$Name]
    if ($c -and $c.ok -and $c.checkedAt -and ((Get-Date) - [datetime]$c.checkedAt).TotalHours -lt 6) { return }
    $err = $null
    try { & $Probe | Out-Null } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($code -notin 400, 401, 403, 404) { Write-Log "$Name self-check skipped (network): $($_.Exception.Message)"; return }
        $err = "$Name rejected the saved credentials: $(Get-ErrorText $_)"
    }
    $was = [bool]($c -and $c.alerted)
    $health.channels[$Name] = @{ checkedAt = (Get-Date).ToString('o'); ok = (-not $err); error = $err; alerted = $was }
    if ($err -and -not $was) { Show-HealthAlert "$Name alerts are not working" $err; $health.channels[$Name].alerted = $true }
    elseif (-not $err -and $was) { Show-HealthAlert "$Name alerts are working again" 'The saved credentials were accepted.'; $health.channels[$Name].alerted = $false }
}

# Read-only Twilio check (no call, no message) so a reset or broken token is noticed before stock appears.
function Test-TwilioHealth {
    $pc = $Config.phoneCall
    if (-not $pc -or -not $pc.twilioAccountSid) { return }
    $t = $health.twilio
    if ($t.ok -and $t.checkedAt -and ((Get-Date) - [datetime]$t.checkedAt).TotalHours -lt 6) { return }
    $err = $null
    if (-not $pc.twilioAuthToken) { $err = 'The Twilio token is missing or could not be decrypted. Paste it into twilioAuthToken in config.json.' }
    else {
        try {
            $a = Invoke-RestMethod -Uri "https://api.twilio.com/2010-04-01/Accounts/$($pc.twilioAccountSid).json" -Headers @{ Authorization = (Get-TwilioAuth) } -TimeoutSec 30
            if ($a.status -ne 'active') { $err = "Your Twilio account is '$($a.status)'." }
        } catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($code -notin 401, 403) { Write-Log "Twilio self-check skipped (network): $($_.Exception.Message)"; return }
            $err = 'Twilio rejected the token (was it reset?). Paste the new Auth Token into twilioAuthToken in config.json.'
        }
    }
    $wasAlerted = [bool]$t.alerted
    $health.twilio = @{ checkedAt = (Get-Date).ToString('o'); ok = (-not $err); error = $err; alerted = $wasAlerted }
    if ($err) {
        Write-Log "Self-check: $err"
        if (-not $wasAlerted) { Show-HealthAlert 'Phone and WhatsApp alerts are not working' $err; $health.twilio.alerted = $true }
    } elseif ($wasAlerted) {
        Show-HealthAlert 'Phone and WhatsApp alerts are working again' 'Twilio accepted the token.'
        $health.twilio.alerted = $false
    }
}

# Config is loaded only now, after logging and self-check are defined, so a broken config.json is logged and counted as a crash.
$Config = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($sf in $SecretFields) {
    $sec = $Config.($sf[0]); $f = $sf[1]
    if ($sec -and -not $sec.$f -and $sec."${f}Encrypted") {
        try { $sec | Add-Member -NotePropertyName $f -NotePropertyValue (Unprotect-Secret $sec."${f}Encrypted") -Force }
        catch { Write-Log "Could not decrypt $($sf[0]).$f; paste it again into config.json. ($($_.Exception.Message))" }
    }
}
if ($Cloud) {
    # telegram, whatsapp and phoneCall are never uploaded with config.json (publish.ps1 -CopySecret puts them in the secret).
    if ($env:TRACKER_SECRETS) {
        $secrets = $env:TRACKER_SECRETS | ConvertFrom-Json
        foreach ($p in $secrets.PSObject.Properties) { $Config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    }
    # GitHub starts the 5-minute schedule late more often than not.
    $Config | Add-Member -NotePropertyName intervalMinutes -NotePropertyValue 10 -Force
    $Config | Add-Member -NotePropertyName autoOpenStorePage -NotePropertyValue $false -Force
    $PrivateValues = @(foreach ($f in 'telegram.botToken', 'telegram.chatId', 'whatsapp.phone', 'whatsapp.metaToken', 'whatsapp.metaPhoneNumberId',
                                      'whatsapp.twilioFrom', 'phoneCall.to', 'phoneCall.twilioAccountSid', 'phoneCall.twilioAuthToken', 'phoneCall.twilioFrom') {
        $sec, $key = $f.Split('.'); $v = "$($Config.$sec.$key)"
        if ($v.Length -ge 4) { $v }
    })
    # GitHub hides only the secret as a whole in the public run logs; this hides each token and number in it too.
    foreach ($v in $PrivateValues) { Write-Host "::add-mask::$v" }
}
# Finds your chat ID from the message you sent the bot, saves it, and sends a test message.
if ($SetupTelegram) {
    $tg = $Config.telegram
    if (-not $tg.botToken) { Write-Host 'First paste your bot token (from @BotFather) into telegram.botToken in config.json.'; return }
    $updates = Invoke-RestMethod -Uri "https://api.telegram.org/bot$($tg.botToken)/getUpdates" -TimeoutSec 30
    $chat = @($updates.result | ForEach-Object { $_.message.chat } | Where-Object { $_ }) | Select-Object -Last 1
    if (-not $chat) { Write-Host 'No message found yet: open your bot in Telegram, press Start (or send "hi"), then run this again.'; return }
    $path = Join-Path $Root 'config.json'
    $raw  = [regex]::Replace((Get-Content $path -Raw -Encoding UTF8), '("chatId"\s*:\s*")[^"]*(")', "`${1}$($chat.id)`${2}")
    $null = $raw | ConvertFrom-Json
    [IO.File]::WriteAllText($path, $raw, (New-Object Text.UTF8Encoding($false)))
    $tg | Add-Member -NotePropertyName chatId -NotePropertyValue "$($chat.id)" -Force
    try { Protect-ConfigSecrets } catch { Write-Log "Could not encrypt secrets: $($_.Exception.Message)" }
    if (Send-Telegram 'iPhone Duo tracker' 'Telegram alerts are set up and working.') { Write-Host "Telegram is set up for $($chat.first_name); test message sent." }
    return
}

if ($TestTelegram) {
    # A sample stock alert, so you can see exactly what a real one looks like.
    $sample = [pscustomobject]@{ Store = 'Sharaf DG'; Variant = '512GB Star White'; State = 'InStock'; Price = 9349
        Vs = "Apple's price (AED 9,349)"; Detail = 'TEST ONLY - in store at City Centre Mirdif, Dubai Mall (call ahead)'
        Url = 'https://uae.sharafdg.com/product/apple-iphone-duo-512gb-star-white-middle-east-version-pre-order/' }
    try { if (Send-Telegram 'TEST - iPhone Duo 512GB AVAILABLE: Sharaf DG' '' $sample.Url $sample) { Write-Host 'Sample Telegram alert sent.' } else { Write-Host 'Telegram is not set up: run tracker.ps1 -SetupTelegram.' } }
    catch { Write-Host "Telegram test failed: $(Get-ErrorText $_)" }
    return
}

if ($TestWhatsApp) {
    try {
        if (Send-WhatsApp '*iPhone Duo tracker*: test message. WhatsApp alerts are working.') { Write-Host "Test WhatsApp sent to $($Config.whatsapp.phone)." }
        else { Write-Host 'WhatsApp is not set up: fill in whatsapp.phone and whatsapp.twilioFrom in config.json.' }
    } catch { Write-Host "WhatsApp test failed: $(Get-ErrorText $_)" }
    return
}

if ($TestCall) {
    if (Send-PhoneCall 'This is a test call from your iPhone Duo stock tracker. Phone alerts are working.') { Write-Host "Test call placed to $($Config.phoneCall.to)." }
    else { Write-Host 'Phone call is not set up: fill in phoneCall in config.json (Twilio account SID, auth token and your Twilio number).' }
    return
}

if ($TestNotify) {
    Send-Alert 'iPhone Duo tracker: test alert' 'If you can read this, notifications work.' 'https://www.apple.com/ae/shop/buy-iphone/iphone-duo' -Urgent
    Write-Host 'Test alert sent (see tracker.log for toast/Telegram result).'
    return
}

# One check at a time: the scheduled task and "Run check now" can overlap, and overlapping runs race on state.json.
# The mutex is released when this process exits; a waiter then gets AbandonedMutexException, which still means it owns it.
# While the watcher holds the lock, "Run check now" leaves a flag file instead, and the watcher checks every store at once.
$CheckNowFlag = Join-Path $Root 'check-now.flag'
$runLock = New-Object System.Threading.Mutex($false, 'Local\iPhoneDuoStockTracker')
try { $gotLock = $runLock.WaitOne([TimeSpan]::FromSeconds($(if ($Watch) { 90 } else { 5 }))) } catch [System.Threading.AbandonedMutexException] { $gotLock = $true }
if (-not $gotLock) {
    if (-not $Watch) { Set-Content -Path $CheckNowFlag -Value (Get-Date).ToString('o'); Write-Log 'Run check now: asked the running watcher to check every store now.'; return }
    Write-Log 'Skipped: another check was still running.'; return
}
if (-not $Cloud) { try { Protect-ConfigSecrets } catch { Write-Log "Could not encrypt secrets in config.json: $($_.Exception.Message)" } }

# Anything that escapes the per-store checks is a crash: log it, and alert after 3 crashed runs in a row (at most every 6 hours).
trap {
    $crash = $_.Exception.Message
    Write-Log "RUN FAILED: $crash"
    try {
        if (-not $health) { $health = Read-Health }
        $health.crashes = [int]$health.crashes + 1
        if ($health.crashes -ge 3 -and (-not $health.crashAlertAt -or ((Get-Date) - [datetime]$health.crashAlertAt).TotalHours -ge 6)) {
            Show-HealthAlert 'iPhone Duo tracker is failing' "The last $($health.crashes) checks failed: $crash (details in tracker.log)."
            $health.crashAlertAt = (Get-Date).ToString('o')
        }
        Save-Health
    } catch { }
    break
}

$health = Read-Health
if ($health.lastRunAt) {
    $gap = (Get-Date) - [datetime]$health.lastRunAt
    if ($gap.TotalMinutes -gt [Math]::Max(10, 3 * [int]$Config.intervalMinutes)) {
        Write-Log ('Self-check: checks were paused for {0}h {1}m (PC asleep, off or signed out).' -f [int][Math]::Floor($gap.TotalHours), $gap.Minutes)
        $health.pauses = @(@($health.pauses) + @([ordered]@{ from = $health.lastRunAt; to = (Get-Date).ToString('o') }) | Select-Object -Last 5)
    }
}

# Emax (Landmark Group): the product page loads stock in the browser from Landmark's inventory API; call it directly.
# applicationId 101 / tenantId are Emax UAE's public storefront context (from the site's app bundle).
# Stock > 0 on a listing flagged "preorder" is pre-order allocation, not stock, so the page flag is checked then.
function Test-Emax($Target) {
    $ctx = '{"applicationId":101,"tenantId":"5DF1363059675161A85F576D"}'
    $api = 'https://uae.emaxme.com/api/inventory/shop-sku-inventory/stock-availability?skuFieldType=SKU_CODE&skuFieldReferences=' +
           [uri]::EscapeDataString($Target.sku)
    $res = Invoke-RestMethod -Uri $api -UserAgent $UA -TimeoutSec 30 -Headers @{ 'X-Context-Request' = $ctx; Accept = 'application/json' }
    $row = @($res) | Where-Object { $_.skuRef.skuCode -eq $Target.sku } | Select-Object -First 1
    if (-not $row) { throw "Emax stock API returned no entry for SKU $($Target.sku) (API changed?)" }
    $units = [int]$row.stock
    if ($units -le 0) { return @{ State = 'OutOfStock'; Detail = 'Online stock: 0 units' } }

    $html = Get-Html $Target.url
    if ($html -notmatch '"initialState":"') { throw 'Emax product page not recognised (blocked or layout changed?)' }
    $b64  = [regex]::Match($html, '"initialState":"([A-Za-z0-9+/=]+)"').Groups[1].Value
    $state = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    if ($state -match '"preorder":true') { return @{ State = 'PreOrder'; Detail = "Pre-order only ($units units allocated)" } }
    @{ State = 'InStock'; Detail = "In stock online: $units unit(s)" }
}

# Links read from store pages are untrusted: they feed the dashboard buttons, the alert click and the auto-opened page,
# so only accept http(s) links on the same site (last two host labels) as the store URL in config.json.
function Test-SameSite([string]$Url, [string]$StoreUrl) {
    $u = $null; $s = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or -not [uri]::TryCreate($StoreUrl, [UriKind]::Absolute, [ref]$s)) { return $false }
    if ($u.Scheme -notin 'https', 'http') { return $false }
    $site = { param($h) (@($h.ToLowerInvariant().Split('.')) | Select-Object -Last 2) -join '.' }
    (& $site $u.Host) -eq (& $site $s.Host)
}

function Invoke-StoreCheck($t) {
    switch ($t.type) {
        'apple'    { Test-Apple $t }
        'jumbo-search'   { Test-JumboStock $t }
        'sharafdg-stock' { Test-SharafDGStock $t }
        'amazon'   { Test-Amazon $t }
        'noon'     { Test-Noon $t }
        'applepickup' { Test-ApplePickup $t }
        'virgin'   { Test-Virgin $t }
        'istyle'   { Test-IStyle $t }
        'ipoint'   { Test-IPoint $t }
        'microless' { Test-Microless $t }
        'carrefour' { Test-Carrefour $t }
        'lulu'     { Test-Lulu $t }
        'dubaidutyfree' { Test-DubaiDutyFree $t }
        'grandstores' { Test-GrandStores $t }
        'cartlow'  { Test-Cartlow $t }
        'revibe'   { Test-Revibe $t }
        'noonminutes' { Test-NoonMinutes $t }
        'du'       { Test-Du $t }
        'eand'     { Test-EAnd $t }
        'emax'     { Test-Emax $t }
        default    { throw "Unknown target type '$($t.type)'" }
    }
}

# All store checks run in parallel; each runspace loads this script's functions and the settings they read.
$functionText = ([Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$null).EndBlock.Statements |
    Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text }) -join "`n"
$worker = {
    param($Target, $FunctionText, $UA, $Config, $Months)
    $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
    # Pool runspaces are reused (constantly in watch mode), so the functions are loaded once per runspace.
    if (-not (Test-Path Function:\Invoke-StoreCheck)) { . ([scriptblock]::Create($FunctionText)) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { @{ Ok = $true; Result = @(Invoke-StoreCheck $Target); Ms = $sw.ElapsedMilliseconds } } catch { @{ Ok = $false; Error = $_.Exception.Message; Ms = $sw.ElapsedMilliseconds } }
}
$parallel = if ($Config.parallelChecks) { [int]$Config.parallelChecks } else { 8 }
$pool = [runspacefactory]::CreateRunspacePool(1, $parallel)
$pool.Open()

# A target with "everyMinutes" (e.g. Amazon, which shows captchas when asked every minute) is checked only that often;
# in between it keeps its last result. The time counts from the last attempt, so a failing store isn't retried sooner.
# In watch mode a target with "everySeconds" is checked that often, and each failure in a row doubles its wait
# (up to 5 minutes), so a store that starts blocking isn't hammered.
function Test-Due($t, $old) {
    if (-not $old -or -not $old.Checked) { return $true }
    $age = ((Get-Date) - [datetime]$old.Checked).TotalSeconds
    if ($Watch -and [int]$t.everySeconds -gt 0) { return $age -ge [Math]::Min(300, [int]$t.everySeconds * [Math]::Pow(2, [Math]::Min(5, [int]$old.Fails))) }
    $minutes = [Math]::Max(1, [int]$t.everyMinutes)
    if (-not $Watch -and $minutes -eq 1) { return $true }
    $age -ge ($minutes * 60 - $(if ($Watch) { $tick } else { 20 }))
}

# The watcher stops just before a scheduled start, so the next one takes over within seconds;
# if it ever dies, the task's 1-minute trigger starts a new one.
function Test-KeepWatching {
    if (-not $Watch) { return $false }
    $now = Get-Date
    if ($now -lt $watchEnd) { return $true }
    if (-not $script:exitAt) {
        $next = try { (Get-ScheduledTaskInfo -TaskName 'iPhone Duo Stock Tracker' -ErrorAction Stop).NextRunTime } catch { $null }
        $script:exitAt = if ($next -and ($next - $now).TotalSeconds -le 90) { $next.AddSeconds(-3) } else { $now }
    }
    $now -lt $script:exitAt
}

$limit       = if ($Config.checkTimeoutSeconds) { [int]$Config.checkTimeoutSeconds } else { 120 }
$tick        = if ($Config.watchTickSeconds) { [Math]::Max(2, [int]$Config.watchTickSeconds) } else { 5 }
$watchEnd    = (Get-Date).AddMinutes($(if ($Config.watchMinutes) { [int]$Config.watchMinutes } else { 60 }))
$runStarted  = Get-Date
$checkMs     = @{}
$checksDone  = 0
$lastSummary = Get-Date
$lastSelfCheck = $null
$lastPage    = $null
$anyTimedOut = $false
$inflight    = @{}   # watch mode: checks still running from an earlier pass, by target key
$passStarted = $null
do {
if ($passStarted) { $rest = ($passStarted.AddSeconds($tick) - (Get-Date)).TotalMilliseconds; if ($rest -gt 0) { Start-Sleep -Milliseconds ([int]$rest) } }
$passStarted = Get-Date
$forceAll = $false
if ($Watch -and (Test-Path $CheckNowFlag)) { Remove-Item -LiteralPath $CheckNowFlag -Force -ErrorAction SilentlyContinue; $forceAll = $true; Write-Log 'Run check now: checking every store.' }

$previous = @{}
if (Test-Path $StatePath) {
    (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $previous[$_.Name] = $_.Value }
}
# Slowest stores (by their last check time) start first, so the run ends close to the slowest single check.
$ordered = @($Config.targets | Sort-Object { $o = $previous["$($_.store) | $($_.variant)"]; if ($o -and $o.Ms) { -[double]$o.Ms } else { 0 } })
$jobs = foreach ($t in $ordered) {
    $key = "$($t.store) | $($t.variant)"
    $old = $previous[$key]
    $j = $inflight[$key]
    if ($j) { $j.Pending = $false; $j.Skipped = $false; $j.Old = $old; $j; continue }
    if (-not $forceAll -and -not (Test-Due $t $old)) {
        [pscustomobject]@{ Target = $t; Skipped = $true; Old = $old; Pending = $false }
        continue
    }
    $ps = [powershell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($worker).AddArgument($t).AddArgument($functionText).AddArgument($UA).AddArgument($Config).AddArgument($Months)
    [pscustomobject]@{ Target = $t; PS = $ps; Handle = $ps.BeginInvoke(); Started = (Get-Date); TimedOut = $false; Pending = $false; Skipped = $false; Old = $old }
}

# One slow store must not stall the whole run (and hold the lock): anything unfinished after the time limit is abandoned
# and reported as an error, which the self-check counts like any other failure. In watch mode a pass waits only
# a few seconds; checks still running then carry over to the next pass and keep their last result meanwhile.
foreach ($j in @($jobs | Where-Object { -not $_.Skipped })) {
    $deadline = $j.Started.AddSeconds($limit)
    # A store with no saved result yet has nothing to show meanwhile, so its first check is waited for.
    $until = if ($Watch -and $j.Old -and $passStarted.AddSeconds($tick) -lt $deadline) { $passStarted.AddSeconds($tick) } else { $deadline }
    if ($j.Handle.AsyncWaitHandle.WaitOne([int][Math]::Max(0, ($until - (Get-Date)).TotalMilliseconds))) { continue }
    if ((Get-Date) -ge $deadline) { $j.TimedOut = $true; $anyTimedOut = $true; try { [void]$j.PS.BeginStop($null, $null) } catch { } }
    else { $j.Pending = $true; $j.Skipped = $true }
}

$results = foreach ($j in $jobs) {
    $t = $j.Target
    $row = [ordered]@{ Key = "$($t.store) | $($t.variant)"; Store = $t.store; Category = $t.category; Variant = $t.variant; Url = $t.url
                       State = 'Error'; Detail = ''; Price = $null; Vs = ''; Skipped = [bool]$j.Skipped; Throttled = ([int]$t.everyMinutes -gt 1) }
    if ($j.Skipped) {
        # Not due this run: show the last result as it was.
        $row.State = if ($j.Old.State -eq 'PreOrder') { 'OutOfStock' } else { $j.Old.State }
        $row.Detail = $j.Old.Detail
        $row.Price = Get-Price $row.Detail
        if (-not $row.Price -and $t.price) { $row.Price = [double]$t.price }
        $row.Vs = Format-OverApple $row.Price
        [pscustomobject]$row
        continue
    }
    try {
        if ($j.TimedOut) { throw "Timed out: no answer within $limit seconds" }
        $out = @($j.PS.EndInvoke($j.Handle)) | Select-Object -Last 1
        if (-not $out) { throw "Check produced no result: $(@($j.PS.Streams.Error)[0])" }
        $checkMs["$($row.Key)"] = $out.Ms
        if (-not $out.Ok) { throw $out.Error }
        $r = @($out.Result) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
        if (-not $r) { throw 'Check returned no status' }
        $row.State = $r.State; $row.Detail = $r.Detail
        if ($r.Url -and (Test-SameSite $r.Url $t.url)) { $row.Url = $r.Url }
        elseif ($r.Url) { Write-Log "Ignored off-site link for $($row.Key): $($r.Url)" }
        # Pre-orders and deposit reservations are reported as out of stock with a note.
        if ($row.State -eq 'PreOrder') {
            $row.State = 'OutOfStock'
            if ($row.Detail -notmatch 'pre-?order|reservation') { $row.Detail = "Pre-order only | $($row.Detail)" }
        }
        # Orderable now but delivered later: still available, with the delivery date up front, unless the target's
        # "deliverBefore" date is missed (the user needs it sooner), which counts as out of stock.
        if ($row.State -eq 'InStock') {
            $eta = Get-EtaDate $row.Detail
            if ($eta -and $t.deliverBefore -and $eta -ge [datetime]$t.deliverBefore) {
                $row.State = 'OutOfStock'
                $row.Detail = "Too late: delivery from $($eta.ToString('d MMM yyyy')), needed before $(([datetime]$t.deliverBefore).ToString('d MMM yyyy')) | $($row.Detail)"
            } elseif ($eta -and ($eta - (Get-Date).Date).TotalDays -gt $Config.availableNowWithinDays) {
                $row.Detail = "Order now, delivery from $($eta.ToString('d MMM yyyy')) | $($row.Detail)"
            }
        }
        # Stores whose "in stock" flag has proved unreliable (sells without stock, or a listing isn't stock).
        if ($row.State -eq 'InStock' -and $t.unverified) {
            $row.State = 'Unverified'
            $row.Detail = "$($row.Detail) | store says in stock but this isn't confirmed; call before going"
        }
        # "price" in config is the store's known list price, used when the check itself reports none.
        $row.Price = Get-Price $r.Detail
        if (-not $row.Price -and $t.price) { $row.Price = [double]$t.price }
        $row.Vs = Format-OverApple $row.Price
    } catch {
        $row.Detail = $_.Exception.Message
        Write-Log "ERROR $($row.Key): $($row.Detail)"
    } finally { if (-not $j.TimedOut) { $j.PS.Dispose() } }
    [pscustomobject]$row
}
$inflight = @{}
foreach ($j in $jobs) { if ($j.Pending) { $inflight["$($j.Target.store) | $($j.Target.variant)"] = $j } }
if (-not @($Config.targets).Count) { throw 'config.json has no stores to check (targets is empty)' }
# Nothing finished in this pass: nothing to save or alert on.
$checksDone += @($results | Where-Object { -not $_.Skipped }).Count
if ($Watch -and -not @($results | Where-Object { -not $_.Skipped }).Count) { continue }

$HistoryPath = Join-Path $Root 'history.json'
$history = New-Object System.Collections.ArrayList
if (Test-Path $HistoryPath) { foreach ($h in (Get-Content $HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json)) { [void]$history.Add($h) } }

$state = @{}
$events = New-Object System.Collections.ArrayList
$checkedAt = (Get-Date).ToString('o')
foreach ($r in $results) {
    $old = $previous[$r.Key]
    if ($r.Skipped) { $state[$r.Key] = $old; continue }
    if ($r.State -eq 'Error') {
        # Keep the last good result; the attempt still counts, so the store waits its full interval (longer while it keeps failing).
        if ($old) { $state[$r.Key] = @{ State = $old.State; Detail = $old.Detail; Checked = $checkedAt; Ms = $old.Ms; Fails = [int]$old.Fails + 1 } }
        continue
    }
    $state[$r.Key] = @{ State = $r.State; Detail = $r.Detail; Checked = $checkedAt; Ms = $checkMs[$r.Key] }
    # Saved states from before pre-orders were folded into out of stock.
    $oldState = if ($old -and $old.State -eq 'PreOrder') { 'OutOfStock' } elseif ($old) { $old.State } else { $null }
    if ($r.State -eq 'InStock' -and $oldState -ne 'InStock') {
        [void]$events.Add(@{ Kind = 'Available'; Row = $r; From = $oldState }); Add-History $r $oldState
    } elseif ($old -and $oldState -ne $r.State) {
        [void]$events.Add(@{ Kind = 'Change'; Row = $r; From = $oldState }); Add-History $r $oldState
    } elseif ($old -and $r.State -eq 'InStock') {
        # Same status: only a moved delivery date is worth an alert, not wording or price-format changes.
        $oldEta = Get-EtaDate $old.Detail; $newEta = Get-EtaDate $r.Detail
        if ($oldEta -and $newEta -and $oldEta -ne $newEta) {
            [void]$events.Add(@{ Kind = 'Eta'; Row = $r; From = ('{0:d MMM}' -f $oldEta); To = ('{0:d MMM}' -f $newEta) }); Add-History $r $r.State
        }
    }
}

# One alert per store and kind of change, so both colours changing together is one message, toast, WhatsApp and call.
foreach ($g in @($events | Group-Object { "$($_.Kind)|$($_.Row.Store)|$($_.From)|$($_.Row.State)|$($_.To)" })) {
    $ev = @($g.Group); $first = $ev[0].Row
    $one = $ev.Count -eq 1
    $row = [pscustomobject]@{ Key = $first.Key; Store = $first.Store; Category = $first.Category; State = $first.State; Url = $first.Url
                              Variant = (@($ev | ForEach-Object { $_.Row.Variant }) -join ' + ')
                              Detail = $(if ($one) { $first.Detail } else { (@($ev | ForEach-Object { "$($_.Row.Variant): $($_.Row.Detail)" }) -join ' | ') })
                              Price = (@($ev | ForEach-Object { $_.Row.Price } | Where-Object { $_ }) | Measure-Object -Minimum).Minimum; Vs = $first.Vs }
    $priceNote = if ($row.Vs) { " Price: $($row.Vs)." } else { '' }
    # The same kind of alert for this store again within 10 minutes (often the other colour a run later) comes
    # quietly: Telegram without sound, no WhatsApp and no second phone call. The window starts at the loud one.
    $coolKey = "$($row.Store)|$($ev[0].Kind)|$($row.State)"
    $lastLoud = $health.lastAlerts[$coolKey]
    $quiet = [bool]($lastLoud -and ((Get-Date) - [datetime]$lastLoud).TotalMinutes -lt 10)
    if (-not $quiet) { $health.lastAlerts[$coolKey] = (Get-Date).ToString('o') }
    switch ($ev[0].Kind) {
        'Available' {
            if ($quiet) { Send-Alert "iPhone Duo 512GB AVAILABLE: $($row.Store)" "$($row.Variant) - $($row.Detail).$priceNote" $row.Url -Row $row -Silent }
            else {
                Send-Alert "iPhone Duo 512GB AVAILABLE: $($row.Store)" "$($row.Variant) - $($row.Detail).$priceNote" $row.Url -Urgent -Row $row
                if (@($Config.priorityStores) -contains $row.Store) { Invoke-PriorityActions $row }
            }
        }
        'Change' {
            $from = $StateLabel[$ev[0].From]; $to = $StateLabel[$row.State]
            Send-Alert "iPhone Duo stock change: $($row.Store) ($from -> $to)" "$($row.Variant): $from -> $to. $($row.Detail)$priceNote" $row.Url -Row $row -Silent:($row.State -eq 'OutOfStock' -or $quiet)
        }
        'Eta' {
            Send-Alert "iPhone Duo delivery date changed: $($row.Store) ($($ev[0].From) -> $($ev[0].To))" "$($row.Variant): $($ev[0].From) -> $($ev[0].To). $($row.Detail)" $row.Url -Row $row
        }
    }
}
$state | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
ConvertTo-Json -InputObject @($history | Select-Object -Last 50) -Depth 3 | Set-Content -Path $HistoryPath -Encoding UTF8

Update-StoreHealth $results
# Alert-channel self-checks at most once a minute in watch mode (they re-check every time while a channel is broken).
if (-not $Watch -or -not $lastSelfCheck -or ((Get-Date) - $lastSelfCheck).TotalSeconds -ge 60) {
    $lastSelfCheck = Get-Date
    try { Test-TwilioHealth } catch { Write-Log "Twilio self-check failed: $($_.Exception.Message)" }
    $wa = $Config.whatsapp
    if ($wa.metaPhoneNumberId -and $wa.metaToken) {
        try { Test-ChannelHealth 'WhatsApp (Meta)' { Invoke-RestMethod -Uri "https://graph.facebook.com/v21.0/$($wa.metaPhoneNumberId)?fields=display_phone_number" -Headers @{ Authorization = "Bearer $($wa.metaToken)" } -TimeoutSec 30 } }
        catch { Write-Log "Meta self-check failed: $($_.Exception.Message)" }
    }
    if ($Config.telegram.botToken) {
        try { Test-ChannelHealth 'Telegram' { Invoke-RestMethod -Uri "https://api.telegram.org/bot$($Config.telegram.botToken)/getMe" -TimeoutSec 30 } }
        catch { Write-Log "Telegram self-check failed: $($_.Exception.Message)" }
    }
}
$health.lastRunAt = (Get-Date).ToString('o')
$health.crashes = 0
Save-Health

# Watch mode rewrites the status file and dashboard when something changed, otherwise every 30 seconds.
$writePage = -not $Watch -or $events.Count -or -not $lastPage -or ((Get-Date) - $lastPage).TotalSeconds -ge 30
if ($writePage) { $lastPage = Get-Date }
$order  = @{ InStock = 0; Unverified = 1; PreOrder = 2; OutOfStock = 3; Error = 4 }
$sorted = $results | Sort-Object { $order[$_.State] }, Store, Variant
$now    = @($results | Where-Object State -eq 'InStock')
$vsApple = @{ n = 'vs Apple'; e = { if ($_.Price -and $Config.applePrice) { '{0:+#,0;-#,0;0}' -f ($_.Price - $Config.applePrice) } } }
$table  = if ($writePage) { $sorted | Format-Table Store, Variant, @{ n = 'Status'; e = { $StateLabel[$_.State] } }, $vsApple, Detail -AutoSize -Wrap | Out-String -Width 240 }
$unconfirmed = @($results | Where-Object State -eq 'Unverified')
$header = "iPhone Duo 512GB - UAE stock check at {0:yyyy-MM-dd HH:mm}`r`nAvailable now (confirmed): {1}`r`nUnconfirmed (call store): {2}" -f (Get-Date),
    $(if ($now) { ($now | ForEach-Object { "$($_.Store) ($($_.Variant))" }) -join ', ' } else { 'nowhere yet' }),
    $(if ($unconfirmed) { ($unconfirmed | ForEach-Object { "$($_.Store) ($($_.Variant))" }) -join ', ' } else { 'none' })
if ($writePage) { "$header`r`n$table" | Set-Content -Path $StatusPath -Encoding UTF8 }
if (-not $Quiet) { Write-Host $header; Write-Host $table }

$template = Join-Path $Root 'dashboard.template.html'
if ($writePage -and (Test-Path $template)) {
    $data = [ordered]@{
        checkedAt       = (Get-Date).ToString('o')
        intervalMinutes = $Config.intervalMinutes
        telegramEnabled = [bool]($Config.telegram.botToken -and $Config.telegram.chatId)
        folder          = $Root
        cloud           = $Cloud
        runUrl          = $RunUrl
        repo            = $(if ($Cloud) { $env:GITHUB_REPOSITORY } else { '' })
        notTracked      = @($Config.notTracked)
        applePrice      = $Config.applePrice
        priority        = @($Config.priorityStores)
        alerts          = [ordered]@{
            phone       = [bool]($Config.phoneCall.to -and $Config.phoneCall.twilioAccountSid -and $Config.phoneCall.twilioAuthToken -and $Config.phoneCall.twilioFrom)
            phoneMasked = $(if ($Config.phoneCall.to -and -not $Cloud) { $n = "$($Config.phoneCall.to)"; $n.Substring(0, [Math]::Min(6, $n.Length)) + ' *** ' + $n.Substring([Math]::Max(0, $n.Length - 4)) } else { '' })
            autoOpen    = [bool]$Config.autoOpenStorePage
            whatsapp    = [bool]($Config.whatsapp.phone -and (($Config.whatsapp.metaPhoneNumberId -and $Config.whatsapp.metaToken) -or ($Config.whatsapp.twilioFrom -and $Config.phoneCall.twilioAuthToken)))
            whatsappVia = $(if ($Config.whatsapp.metaPhoneNumberId -and $Config.whatsapp.metaToken) { 'your Meta template' } elseif ($Config.whatsapp.twilioFrom) { 'Twilio (fixed text)' } else { '' })
        }
        history         = @($history | Select-Object -Last 20)
        health          = [ordered]@{
            problems = @(
                foreach ($k in $health.stores.Keys) {
                    $s = $health.stores[$k]
                    if ($s.fails -ge 2) { [ordered]@{ title = "$k can't be checked"; detail = "$($s.fails) failed checks in a row: $($s.error)" } }
                }
                if ($health.twilio.error) { [ordered]@{ title = 'Phone and WhatsApp alerts'; detail = $health.twilio.error } }
                foreach ($n in $health.channels.Keys) { if ($health.channels[$n].error) { [ordered]@{ title = "$n alerts"; detail = $health.channels[$n].error } } }
            )
            twilioOk        = $health.twilio.ok
            twilioCheckedAt = $health.twilio.checkedAt
            lastPause       = @($health.pauses) | Select-Object -Last 1
        }
        # Store logos saved by fetch-logos.ps1, keyed by the store-name slug the dashboard derives.
        logos           = $(
            $map = [ordered]@{}
            $logoDir = Join-Path $Root 'logos'
            if (Test-Path $logoDir) {
                Get-ChildItem $logoDir -File | Where-Object { $_.Extension -match '^\.(png|jpe?g|gif|webp|ico|svg)$' } |
                    ForEach-Object { $map[$_.BaseName] = "logos/$($_.Name)" }
            }
            $map)
        results         = @($sorted | ForEach-Object {
            $eta = if ($_.State -in 'InStock', 'PreOrder') { Get-EtaDate $_.Detail } else { $null }
            [ordered]@{ store = $_.Store; category = $_.Category; variant = $_.Variant; state = $_.State; detail = $_.Detail; url = $_.Url
                        eta = $(if ($eta) { $eta.ToString('yyyy-MM-dd') } else { $null }); price = $_.Price }
        })
    }
    # Store text is untrusted; stop it from closing the <script> block it is embedded in.
    $json = ($data | ConvertTo-Json -Depth 5 -Compress) -replace '</', '<\/'
    (Get-Content $template -Raw -Encoding UTF8).Replace('/*TRACKER_DATA*/null', $json) |
        Set-Content -Path (Join-Path $Root 'dashboard.html') -Encoding UTF8
}

if (-not $Watch -or ((Get-Date) - $lastSummary).TotalSeconds -ge 60) {
    $counts = ($results | Group-Object State | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
    # The slowest checks decide how often a store can really be re-checked.
    $slow = @($checkMs.Keys | Sort-Object { -$checkMs[$_] } | Select-Object -First 3 | ForEach-Object { '{0} {1:N0}s' -f $_, ($checkMs[$_] / 1000) })
    $what = if ($Watch) { "Watching: $checksDone checks in the last minute" } else { 'Run complete in {0:N0}s' -f ((Get-Date) - $runStarted).TotalSeconds }
    Write-Log ("{0}: {1}{2}" -f $what, $counts, $(if ($slow) { " | slowest: $($slow -join ', ')" }))
    $lastSummary = Get-Date; $checkMs = @{}; $checksDone = 0
}
} while (Test-KeepWatching)
# Closing the pool would wait for abandoned or still-running checks; leave it to process exit in that case.
if (-not $anyTimedOut -and -not $inflight.Count) { $pool.Close() }
