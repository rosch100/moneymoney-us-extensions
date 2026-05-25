---@diagnostic disable: undefined-global
--
-- Equiniti Shareview Portfolio — MoneyMoney Web Banking Extension
-- https://portfolio.shareview.co.uk
-- Dokumentation: docs/LUA-EXTENSIONS.md
-- API: https://moneymoney.app/api/webbanking/
--

WebBanking{
  version     = 1.00,
  url         = "https://portfolio.shareview.co.uk",
  services    = {"Shareview"},
  description = "Equiniti Shareview Portfolio - Direct Login (Username + Password + DOB + MFA)"
}

local CONSTANTS = {
  baseUrl     = "https://portfolio.shareview.co.uk",
  loginUrl    = "https://portfolio.shareview.co.uk/7/Portfolio/default/en/anonymous/Pages/Login.aspx",
  holdingsUrl = "https://portfolio.shareview.co.uk/7/portfolio/default/en/Active/Pages/holdingssummary.aspx",
  logoutUrl   = "https://portfolio.shareview.co.uk/7/Auth/Logoff.aspx",
  userAgent   = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

local connection
local session = { cookies = "" }

-- ============================================================================
-- Hilfsfunktionen
-- ============================================================================

local function trim(text)
  if not text then return "" end
  return (text:gsub("^%s*(.-)%s*$", "%1"))
end

local function htmlDecode(text)
  if not text then return "" end
  text = text:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
             :gsub("&quot;", "\""):gsub("&#39;", "'"):gsub("&nbsp;", " ")
  text = text:gsub("&#x([%da-fA-F]+);", function(h)
    local n = tonumber(h, 16); return n and string.char(n) or ""
  end)
  text = text:gsub("&#(%d+);", function(d)
    local n = tonumber(d); return n and string.char(n) or ""
  end)
  return text
end

local function stripTags(s)
  if not s then return "" end
  return trim(htmlDecode((s:gsub("<[^>]+>", " "):gsub("%s+", " "))))
end

-- DOB-Helper sind global, damit tests/test_shareview.lua sie direkt aufrufen kann.
function parseDobString(raw)
  if not raw then return nil, nil, nil end
  local d, m, y = trim(raw):match("^(%d+)[%./%-](%d+)[%./%-](%d+)$")
  if not d then return nil, nil, nil end
  return tonumber(d), tonumber(m), tonumber(y)
end

function isValidDob(day, month, year)
  if not (day and month and year) then return false end
  if day   < 1    or day   > 31   then return false end
  if month < 1    or month > 12   then return false end
  if year  < 1900 or year  > 2100 then return false end
  return true
end

-- Username + optionales "|TT.MM.JJJJ" parsen. DOB nil -> Multi-Step-Abfrage.
function parseUsernameDob(rawUsername)
  if not rawUsername or rawUsername == "" then return nil end
  local user, dob = rawUsername:match("^([^|]+)|(.+)$")
  if not user then return trim(rawUsername) end
  return trim(user), parseDobString(dob)
end

-- Currency-Format aus Shareview-HTML, z.B. "GBX|10.0000|99|1|.|,|6".
-- Rückgabe: amountInGbp, nativeCurrency, nativeAmount.
function parseCurrencyValue(raw)
  if not raw then return nil, nil, nil end
  local parts = {}
  for part in (raw .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = part end
  if #parts < 2 then return nil, nil, nil end
  local currency = trim(parts[1])
  local value = tonumber(parts[2])
  if not value then return nil, nil, nil end
  if currency == "GBX" or currency == "GBp" then return value / 100, "GBX", value end
  return value, currency, value
end

local function normalizeCurrency(c)
  if c == "GBX" or c == "GBp" then return "GBP" end
  if not c or c == "" then return "GBP" end
  return c
end

-- Form-Submit über die MoneyMoney-HTML/XPath-API.
-- Connection:request liefert (content, charset, mimeType, filename, headers).
-- Wir geben nur `content` zurück, damit die Caller mit (content, err) sicher
-- destrukturieren koennen — sonst landet "utf-8" als zweiter Rueckgabewert
-- und wird als Fehlertext interpretiert.
-- Wenn die XPath-Suche leer ist: nil + Fehlertext.
local function submitForm(formNode)
  if not formNode or formNode:length() == 0 then
    return nil, "Form-Element nicht gefunden (XPath traf nicht)."
  end
  local content = connection:request(formNode:submit())
  return content
end

-- ============================================================================
-- WebBanking-Lifecycle
-- ============================================================================

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Shareview"
end

-- Step 1 erhält {username, password} aus dem Keychain. Folge-Steps werden
-- state-basiert dispatcht, weil zwischen Step 1 und MFA optional ein
-- DOB-Step liegt (wenn der Username keinen "|TT.MM.JJJJ"-Suffix enthält).
function InitializeSession2(protocol, bankCode, step, credentials, interactive)
  if step == 1 then
    connection = Connection()
    connection.language = "en-GB"
    connection.useragent = CONSTANTS.userAgent
    return loginStep1(credentials, interactive)
  end
  if session.awaitingDob then return submitDobAndLogin(credentials[1]) end
  if session.awaitingMfa then return submitMfaCode(credentials) end
  return LoginFailed
end

function loginStep1(credentials, interactive)
  local rawUsername = credentials[1]
  local password    = credentials[2]

  if not password or password == "" then return LoginFailed end
  if password:match("^COOKIE:") then return loginWithImportedCookies(password:sub(8)) end

  local username, day, month, year = parseUsernameDob(rawUsername)
  if not username or username == "" then
    return "Bitte einen Shareview-Benutzernamen eingeben."
  end

  if day and month and year then
    if not isValidDob(day, month, year) then
      return "Ungültiges Geburtsdatum im Benutzernamen. Format: \"username|TT.MM.JJJJ\"."
    end
    return submitCredentials(username, password, day, month, year)
  end

  if interactive == false then
    return "Geburtsdatum fehlt. Bitte den Benutzernamen einmalig als \"username|TT.MM.JJJJ\" speichern (z.B. \"" .. username .. "|01.01.1970\"), damit das automatische Sync funktioniert."
  end

  session.awaitingDob = true
  session.pendingUsername = username
  session.pendingPassword = password
  return {
    title     = "Geburtsdatum erforderlich",
    challenge = "Bitte das Geburtsdatum für Shareview eingeben (Format TT.MM.JJJJ).\n\nTipp: Speichere es dauerhaft als Teil des Benutzernamens (\"" .. username .. "|01.01.1970\"), dann entfällt diese Abfrage künftig.",
    label     = "Geburtsdatum (TT.MM.JJJJ)"
  }
end

function submitDobAndLogin(dobRaw)
  session.awaitingDob = false
  local username, password = session.pendingUsername, session.pendingPassword
  session.pendingUsername, session.pendingPassword = nil, nil
  if not username or not password then return LoginFailed end

  local day, month, year = parseDobString(dobRaw)
  if not isValidDob(day, month, year) then
    return "Ungültiges Geburtsdatum. Erwartet: TT.MM.JJJJ (z.B. 01.01.1970)."
  end
  return submitCredentials(username, password, day, month, year)
end

-- Login-POST via HTML/XPath. Bei Erfolg: setzt session.awaitingMfa.
function submitCredentials(username, password, day, month, year)
  MM.printStatus("Shareview: Zugangsdaten senden...")
  local content = connection:get(CONSTANTS.loginUrl)
  if not content or content == "" then
    return "Login fehlgeschlagen: Login-Seite nicht erreichbar."
  end

  local html = HTML(content)

  -- ASP.NET-WebForms: die `id`-Attribute enthalten dynamische GUIDs, daher
  -- per `contains(@id, "...")`-Substring-Match auf die stabilen Suffixe.
  html:xpath('//input[contains(@id, "UserLocate2UC1_rpt_ctl00_txtInput")]'):attr("value", username)
  html:xpath('//input[contains(@id, "UserLocate2UC1_rpt_ctl02_txtInput")]'):attr("value", password)
  html:xpath('//select[contains(@id, "drpDay")]/option[@value="'   .. day   .. '"]'):attr("selected", "selected")
  html:xpath('//select[contains(@id, "drpMonth")]/option[@value="' .. month .. '"]'):attr("selected", "selected")
  html:xpath('//select[contains(@id, "drpYear")]/option[@value="'  .. year  .. '"]'):attr("selected", "selected")

  -- ASP.NET-Postback: __EVENTTARGET = Name des Locate-Buttons
  local locateBtn = html:xpath('//input[contains(@id, "btnLocate") or contains(@name, "btnLocate")]'):attr("name")
  html:xpath('//input[@name="__EVENTTARGET"]'):attr("value", locateBtn or "")

  -- Die Form wird per name selektiert (id ist dynamisch, z.B. "ctl31").
  local mfaContent, submitErr = submitForm(html:xpath('//form[@name="aspnetForm"]'))
  if submitErr then return "Login fehlgeschlagen: " .. submitErr end
  if not mfaContent or mfaContent == "" then
    return "Login fehlgeschlagen: Keine Antwort vom Server."
  end

  if isLoggedInPage(mfaContent) then
    session.holdingsHtmlString = mfaContent
    return nil
  end

  local loginError = extractLoginError(HTML(mfaContent))
  if loginError then return "Login fehlgeschlagen: " .. loginError end
  if not isMfaPage(mfaContent) then
    return "Login fehlgeschlagen: Unerwartete Antwort. Bitte Zugangsdaten und Geburtsdatum prüfen."
  end

  session.mfaHtmlString = mfaContent
  session.awaitingMfa = true
  return {
    title     = "Shareview Authentifizierung",
    challenge = "Bitte den 6-stelligen Authentication Code aus der Shareview-App oder E-Mail eingeben.",
    label     = "Authentication Code"
  }
end

function submitMfaCode(credentials)
  session.awaitingMfa = false
  local code = credentials[1]
  if not code or not code:match("^%s*%d+%s*$") then
    return "Ungültiger Authentication Code: nur Ziffern erwartet."
  end
  code = trim(code)

  if not session.mfaHtmlString then return LoginFailed end
  local mfaHtml = HTML(session.mfaHtmlString)

  mfaHtml:xpath('//input[contains(@id, "txtVerificationCode") or contains(@name, "txtVerificationCode")]'):attr("value", code)
  local submitBtn = mfaHtml:xpath('//input[contains(@id, "btnSubmitOtp") or contains(@name, "btnSubmitOtp")]'):attr("name")
  mfaHtml:xpath('//input[@name="__EVENTTARGET"]'):attr("value", submitBtn or "")

  MM.printStatus("Shareview: Authentication Code senden...")
  local otpResponse, submitErr = submitForm(mfaHtml:xpath('//form[@name="aspnetForm"]'))
  session.mfaHtmlString = nil

  if submitErr then return "MFA fehlgeschlagen: " .. submitErr end
  if not otpResponse then
    return "MFA fehlgeschlagen: Keine Antwort vom Server."
  end

  if otpResponse:match("Please enter a 6 digit Authentication Code")
     or otpResponse:match('id="otpErrorLabelWrapper"[^>]*>%s*<span>') then
    return "Authentication Code abgelehnt. Bitte erneut versuchen."
  end

  -- WS-Federation/SAML-Hops nachfahren (Browser würde via JS auto-submitten).
  otpResponse = followFederationHops(otpResponse, 5)

  local holdings = connection:get(CONSTANTS.holdingsUrl)
  if holdings and isLoggedInPage(holdings) then
    session.holdingsHtmlString = holdings
    return nil
  end

  if otpResponse and otpResponse:lower():match("authentication code") then
    return "Authentication Code abgelehnt. Bitte erneut versuchen."
  end
  return "MFA fehlgeschlagen. Bitte Cookie-Import verwenden."
end

-- ADFS / WS-Federation-Pages enthalten <form name="hiddenform">, die der
-- Browser per document.forms[0].submit() automatisch absendet. Wir machen
-- dasselbe per :submit(), bis keine Auto-Post-Page mehr kommt.
function followFederationHops(content, maxHops)
  for _ = 1, (maxHops or 5) do
    if not content or content == "" then return content end
    local html = HTML(content)
    local form = html:xpath('//form[@name="hiddenform"]')
    local title = html:xpath('//title'):text() or ""
    local isAutoPost = title:match("Working") ~= nil
                       or content:match("document%.forms%[0%]%.submit") ~= nil
                       or content:match('<form[^>]+name="hiddenform"') ~= nil
    if not isAutoPost or not form or form:length() == 0 then return content end

    local nextContent, hopErr = submitForm(form)
    if hopErr then return content end
    content = nextContent
  end
  return content
end

-- ============================================================================
-- Cookie-Import-Modus (Passwort beginnt mit "COOKIE:")
-- ============================================================================

function loginWithImportedCookies(cookieString)
  local formatted = trim(cookieString)
  if formatted:match(",") and not formatted:match(";") then
    formatted = formatted:gsub("%s*,%s*", "; ")
  end
  if not formatted:match("=") then
    return "Ungültiges Cookie-Format. Erwartet: name=value;name2=value2"
  end
  if not formatted:match("FedAuth=") then
    return "FedAuth-Cookie fehlt. Bitte erneut nach erfolgreichem Login exportieren."
  end

  local response = connection:request("GET", CONSTANTS.holdingsUrl, nil, nil, {
    ["Accept"]          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Accept-Language"] = "en-GB,en;q=0.9",
    ["Cookie"]          = formatted
  })

  if not response or not isLoggedInPage(response) then
    return "Cookie-Import fehlgeschlagen. Cookies abgelaufen — bitte erneut exportieren."
  end

  session.cookies = formatted
  session.holdingsHtmlString = response
  return nil
end

-- ============================================================================
-- Login-Status / Fehler-Erkennung
-- ============================================================================

function isLoggedInPage(content)
  if not content then return false end
  if content:match('id="TotalIndicativeValue"') then return true end
  if content:match("My Holdings Summary") then return true end
  if content:find("holdingssummary", 1, true) and content:match("BaseHoldingSummaryUC1") then
    return true
  end
  return false
end

function isMfaPage(content)
  if not content then return false end
  return content:lower():find("authentication code", 1, true) ~= nil
end

function extractLoginError(htmlNode)
  if not htmlNode then return nil end
  local candidates = {
    '//*[contains(@class, "ErrorMessage")]',
    '//*[contains(@id, "lblError")]',
    '//*[contains(@id, "ErrorLabel")]'
  }
  for _, xp in ipairs(candidates) do
    local node = htmlNode:xpath(xp)
    if node then
      local text = trim(node:text() or "")
      if text ~= "" then return text end
    end
  end
  return nil
end

-- ============================================================================
-- ListAccounts / RefreshAccount
-- ============================================================================

function ListAccounts(knownAccounts)
  if not session.holdingsHtmlString then
    session.holdingsHtmlString = connection:get(CONSTANTS.holdingsUrl)
  end
  if not session.holdingsHtmlString or not isLoggedInPage(session.holdingsHtmlString) then
    return "Holdings-Seite nicht zugänglich. Session abgelaufen?"
  end
  return {
    {
      name          = "Shareview Portfolio",
      accountNumber = "shareview-portfolio",
      portfolio     = true,
      currency      = "GBP",
      type          = AccountTypePortfolio,
      bankCode      = "Shareview"
    }
  }
end

function RefreshAccount(account, since)
  if not session.holdingsHtmlString then
    session.holdingsHtmlString = connection:get(CONSTANTS.holdingsUrl)
  end
  if not session.holdingsHtmlString then
    return "Holdings-Seite nicht erreichbar."
  end

  local html = session.holdingsHtmlString
  local securities = parseHoldings(html)
  local balance, balanceCurrency = parseTotalIndicativeValue(html)

  if not balance or balance == 0 then
    balance = 0
    for _, sec in ipairs(securities) do balance = balance + (sec.amount or 0) end
    balanceCurrency = balanceCurrency or "GBP"
  end
  return { balance = balance, securities = securities }
end

function parseTotalIndicativeValue(htmlString)
  if not htmlString then return nil, nil end
  local block = htmlString:match('id="TotalIndicativeValue"[^>]*>%s*<span[^>]*>([^<]+)<')
                or htmlString:match('id="TotalIndicativeValue".-currencyChange[^>]*>([^<]+)<')
  if not block then return nil, nil end
  local amount, native = parseCurrencyValue(block)
  return amount, normalizeCurrency(native)
end

function parseHoldings(htmlString)
  local securities = {}
  if not htmlString then return securities end
  for row in htmlString:gmatch('<tr[^>]*summaryDataItemRow[^>]*>(.-)</tr>') do
    local sec = parseHoldingRow(row)
    if sec then securities[#securities + 1] = sec end
  end
  return securities
end

local function extractIsin(row)
  -- Lua-Patterns kennen kein {n}; daher per Längen-/Format-Check validieren.
  local candidate = row:match("externalid=([A-Z0-9]+)") or ""
  if #candidate == 12 and candidate:match("^[A-Z][A-Z][A-Z0-9]+[0-9]$") then
    return candidate
  end
  return ""
end

local function extractCurrencyCell(cell)
  if not cell then return nil end
  return cell:match('<span class="original">([^<]+)</span>')
      or cell:match('currencyChange[^>]*>([^<]+)<span')
      or cell:match('currencyChangeIgnoreNative[^>]*>([^<]+)<span')
end

function parseHoldingRow(row)
  if not row then return nil end

  local holdingCell = row:match('headers="holding"[^>]*>(.-)</td>') or ""
  local name = trim(htmlDecode(holdingCell:match("<strong>%s*([^<]+)%s*</strong>") or ""))
  if name == "" then return nil end

  local subAccount = holdingCell:match("</strong>%s*<br/?>%s*([^<]+)")
  if subAccount then subAccount = trim(htmlDecode(subAccount)) end
  local fullName = name
  if subAccount and subAccount ~= "" and not subAccount:match("Shareholder Ref") then
    fullName = name .. " (" .. subAccount .. ")"
  end

  local shareholderRef = trim(holdingCell:match("Shareholder Ref No:%s*([%w%-]+)") or "")

  local quantityCell = row:match('headers="quantity"[^>]*>(.-)</td>') or ""
  local quantityStr  = (quantityCell:match('<bdo[^>]*>%s*([%d%.,]+)%s*</bdo>') or stripTags(quantityCell) or ""):gsub(",", "")
  local quantity     = tonumber(quantityStr) or 0

  local priceCell = row:match('headers="price"[^>]*>(.-)</td>')
  local pricePerShare, priceNative = parseCurrencyValue(extractCurrencyCell(priceCell))

  local valueCell = row:match('headers="value"[^>]*>(.-)</td>')
  local amount, valueNative = parseCurrencyValue(extractCurrencyCell(valueCell))

  if not amount and pricePerShare and quantity > 0 then
    amount = pricePerShare * quantity
  end

  return {
    name                     = fullName,
    isin                     = extractIsin(row),
    securityNumber           = shareholderRef,
    quantity                 = quantity,
    price                    = pricePerShare or 0,
    currencyOfPrice          = normalizeCurrency(priceNative),
    amount                   = amount or 0,
    currencyOfOriginalAmount = normalizeCurrency(valueNative)
  }
end

-- ============================================================================
-- EndSession
-- ============================================================================

function EndSession()
  if connection then
    pcall(function() connection:get(CONSTANTS.logoutUrl) end)
  end
  session = { cookies = "" }
  connection = nil
end

-- SIGNATURE: <unsigned>
