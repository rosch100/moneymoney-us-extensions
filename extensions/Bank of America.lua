--
-- MoneyMoney Web Banking extension for Bank of America
-- https://www.bankofamerica.com
--
-- MIT License
--
-- COOKIE IMPORT MODE (Workaround for RSA encryption):
--   Bank of America uses client-side RSA encryption for login that cannot
--   be replicated in Lua. Use Cookie Import Mode as a workaround:
--
--   1. Login to Bank of America in your browser (Safari/Chrome)
--   2. Open DevTools (F12) → Application/Storage → Cookies
--   3. Copy ALL cookies for secure.bankofamerica.com (especially critical ones):
--      Best: DevTools → Network → any account-details.go request → Request Headers → Cookie (full string)
--      - SMSESSION (JWT session token - MOST IMPORTANT)
--      - SSOTOKEN, LSESSIONID, GSID, CSID, MMID, cdSNum, ctd
--      - Akamai/session helpers: bm_sv, bm_sz, bmuid, ak_bmsc, TS017f5af8, TS0156185e
--   4. In MoneyMoney, enter your username normally
--   5. For password, enter: COOKIE: followed by semicolon-separated cookies
--      Example: COOKIE:SMSESSION=eyJ...;SSOTOKEN=eyJ...;LSESSIONID=eyJ...;GSID=...
--
--   The extension will use these cookies to access your account directly,
--   bypassing the RSA-encrypted login flow.
--
-- ARCHITECTURE NOTES:
--   Bank of America uses server-side rendering, not JSON APIs.
--   Account data is embedded in HTML responses.
--   Main endpoint: /myaccounts/
--

WebBanking {
  version = "1.0.0",
  url = "https://secure.bankofamerica.com",
  services = {"Bank of America"},
  description = "Bank of America - Cookie Import mode (workaround for RSA encryption)"
}

local CONSTANTS = {
  baseUrl = "https://secure.bankofamerica.com",
  bankCode = "BOA",
  userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15"
}

local connection
local session = { cookies = "", adxToken = "", statementPageUrl = "" }

local function trimCookiePart(value)
  return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function mergeCookies(existingCookies, newCookies)
  if not newCookies or newCookies == "" then
    return existingCookies or ""
  end

  local cookieMap = {}
  if existingCookies and existingCookies ~= "" then
    for part in existingCookies:gmatch("[^;]+") do
      local name, value = part:match("^([^=]+)=(.+)$")
      if name then
        cookieMap[trimCookiePart(name)] = trimCookiePart(value)
      end
    end
  end

  for part in newCookies:gmatch("[^;]+") do
    local name, value = part:match("^([^=]+)=(.+)$")
    if name then
      cookieMap[trimCookiePart(name)] = trimCookiePart(value)
    end
  end

  local merged = {}
  for name, value in pairs(cookieMap) do
    table.insert(merged, name .. "=" .. value)
  end
  return table.concat(merged, "; ")
end

local function refreshSessionCookies()
  if not connection or type(connection.getCookies) ~= "function" then
    return
  end
  local newCookies = connection:getCookies()
  if newCookies and newCookies ~= "" then
    session.cookies = mergeCookies(session.cookies, newCookies)
  end
end

local function syncCookieHeader(requestHeaders)
  requestHeaders["Cookie"] = session.cookies
end

local function performGet(url, requestHeaders, refererUrl)
  if refererUrl then
    requestHeaders["Referer"] = refererUrl
  end
  syncCookieHeader(requestHeaders)
  local response, status, mimeType = connection:request("GET", url, nil, nil, requestHeaders)
  refreshSessionCookies()
  syncCookieHeader(requestHeaders)
  return response, status, mimeType
end

local function performPost(url, postData, contentType, requestHeaders, refererUrl)
  if refererUrl then
    requestHeaders["Referer"] = refererUrl
  end
  syncCookieHeader(requestHeaders)
  local body = postData or ""
  local response, status, mimeType = connection:request("POST", url, body, contentType, requestHeaders)
  refreshSessionCookies()
  syncCookieHeader(requestHeaders)
  return response, status, mimeType
end

local function buildRequestHeaders(refererUrl)
  local headers = {
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Accept-Language"] = "en-US,en;q=0.9",
    ["User-Agent"] = CONSTANTS.userAgent,
    ["Sec-Fetch-Site"] = "same-origin",
    ["Sec-Fetch-Mode"] = "navigate",
    ["Sec-Fetch-Dest"] = "document",
    ["Cookie"] = session.cookies
  }
  if refererUrl then
    headers["Referer"] = refererUrl
  end
  return headers
end

local function buildAjaxPostHeaders(refererUrl)
  return {
    ["Accept"] = "*/*",
    ["Accept-Language"] = "en-US,en;q=0.9",
    ["Origin"] = CONSTANTS.baseUrl,
    ["User-Agent"] = CONSTANTS.userAgent,
    ["Sec-Fetch-Site"] = "same-origin",
    ["Sec-Fetch-Mode"] = "cors",
    ["Sec-Fetch-Dest"] = "empty",
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Referer"] = refererUrl,
    ["Cookie"] = session.cookies
  }
end

local function buildJsonPostHeaders(refererUrl)
  return {
    ["Accept"] = "*/*",
    ["Accept-Language"] = "en-US,en;q=0.9",
    ["Content-Type"] = "application/json; charset=UTF-8",
    ["Origin"] = CONSTANTS.baseUrl,
    ["User-Agent"] = CONSTANTS.userAgent,
    ["Sec-Fetch-Site"] = "same-origin",
    ["Sec-Fetch-Mode"] = "cors",
    ["Sec-Fetch-Dest"] = "empty",
    ["Referer"] = refererUrl,
    ["Cookie"] = session.cookies
  }
end

local function buildPdfGetHeaders(refererUrl)
  return {
    ["Accept"] = "application/pdf,application/octet-stream,*/*",
    ["Accept-Language"] = "en-US,en;q=0.9",
    ["User-Agent"] = CONSTANTS.userAgent,
    ["Sec-Fetch-Site"] = "same-origin",
    ["Sec-Fetch-Mode"] = "navigate",
    ["Sec-Fetch-Dest"] = "document",
    ["Referer"] = refererUrl,
    ["Cookie"] = session.cookies
  }
end

local function extractStatementPageUrl(html)
  for urlMatch in html:gmatch('["\']([^"\']*mycommunications/statements/statement%.go[^"\']*)["\']') do
    local url = urlMatch:gsub("&amp;", "&")
    if url:sub(1, 1) == "/" then
      url = CONSTANTS.baseUrl .. url
    elseif not url:find("^http") then
      url = CONSTANTS.baseUrl .. "/" .. url
    end
    return url
  end
  return nil
end

local function rememberStatementPageUrl(html, adxToken)
  local statementUrl = extractStatementPageUrl(html)
  if statementUrl then
    session.statementPageUrl = statementUrl
    return
  end

  local profileEligibility = html:match("profileEligibilty=([A-Z0-9]+)")
  if not profileEligibility or not adxToken then
    return
  end

  local returnSiteIndicator = html:match("returnSiteIndicator=([A-Z]+)") or "GAIMW"
  session.statementPageUrl = CONSTANTS.baseUrl ..
    "/mycommunications/statements/statement.go?request_locale=en-us" ..
    "&profileEligibilty=" .. profileEligibility ..
    "&adx=" .. adxToken ..
    "&source=adc&returnSiteIndicator=" .. returnSiteIndicator
end

local function buildStatementPageUrl(adxToken)
  if session.statementPageUrl and session.statementPageUrl ~= "" then
    local url = session.statementPageUrl:gsub("&amp;", "&")
    if adxToken and not url:find("adx=") then
      url = url .. (url:find("%?") and "&" or "?") .. "adx=" .. adxToken
    end
    return url
  end

  return CONSTANTS.baseUrl ..
    "/mycommunications/statements/statement.go?request_locale=en-us&source=adc&adx=" .. adxToken
end

local function normalizeStatementPeriodUrl(urlMatch)
  local url = urlMatch:gsub("&amp;", "&")
  if url:sub(1, 1) == "/" then
    url = CONSTANTS.baseUrl .. url
  elseif not url:find("^http") then
    if url:find("account%-details%.go") then
      url = CONSTANTS.baseUrl .. "/myaccounts/details/card/" .. url
    else
      url = CONSTANTS.baseUrl .. "/" .. url
    end
  end

  if not url:find("filter=") then
    if url:find("%?") then
      url = url .. "&filter=0&sort=0&order=0"
    else
      url = url .. "?filter=0&sort=0&order=0"
    end
  end

  return url
end

local function mergeTransactions(allTransactions, seenTransactions, pageTransactions)
  for _, trans in ipairs(pageTransactions) do
    local key = (trans.bookingDate or "") .. "|" .. (trans.purpose or "") .. "|" .. tostring(trans.amount)
    if not seenTransactions[key] then
      seenTransactions[key] = true
      table.insert(allTransactions, trans)
    end
  end
end

local function isActivityTransactionUrl(urlMatch)
  if urlMatch:find("download%-transactions%.go") then
    return false
  end
  if urlMatch:find("downloadStmtFromDateList") then
    return false
  end
  return urlMatch:find("target=stmtFromDateList") or
         urlMatch:find("target=stmtFromPreviousLink") or
         urlMatch:find("target=stmtFromNextLink")
end

local function extractGotoSelectTransTop(html)
  local lower = html:lower()
  local selectStart = lower:find('id="goto_select_trans_top"', 1, true)
  if not selectStart then
    return nil
  end
  local selectEnd = lower:find("</select>", selectStart)
  if not selectEnd then
    return nil
  end
  return html:sub(selectStart, selectEnd + 9)
end

local function extractActivityPeriodOptions(html)
  local options = {}
  local section = extractGotoSelectTransTop(html)
  if not section then
    return options
  end

  local pos = 1
  while true do
    local optStart, optEnd = section:lower():find("<option", pos)
    if not optStart then
      break
    end
    local optClose = section:lower():find("</option>", optEnd + 1)
    if not optClose then
      break
    end
    local optionHtml = section:sub(optStart, optClose + 9)
    pos = optClose + 9

    local urlMatch = optionHtml:match('value="([^"]*target=stmtFromDateList[^"]*)"')
    local label = optionHtml:match(">([^<]+)</option>")
    if urlMatch and label and isActivityTransactionUrl(urlMatch) then
      table.insert(options, {
        label = label:gsub("^%s*", ""):gsub("%s*$", ""),
        url = normalizeStatementPeriodUrl(urlMatch)
      })
    end
  end

  return options
end

local function collectActivityPeriodLabels(html)
  local labels = {}
  local seen = {}
  for _, opt in ipairs(extractActivityPeriodOptions(html)) do
    if not seen[opt.label] then
      seen[opt.label] = true
      table.insert(labels, opt.label)
    end
  end
  return labels
end

local function findActivityPeriodUrl(html, periodLabel)
  for _, opt in ipairs(extractActivityPeriodOptions(html)) do
    if opt.label == periodLabel then
      return opt.url
    end
  end
  return nil
end

local function updateAdxFromResponse(response, adxToken)
  local responseAdx = response:match('adx=["\']?([0-9a-f]+)') or
                      response:match('["\']adx["\']%s*[:=]%s*["\']?([0-9a-f]+)')
  if responseAdx then
    session.adxToken = responseAdx
    return responseAdx
  end
  return adxToken
end

local function asActivityDateListUrl(url)
  if not url then
    return nil
  end
  return url:gsub("target=stmtFromPreviousLink", "target=stmtFromDateList")
           :gsub("target=stmtFromNextLink", "target=stmtFromDateList")
end

local function extractPreviousPeriodUrl(html)
  for urlMatch in html:gmatch('["\']([^"\']*target=stmtFromPreviousLink[^"\']*)["\']') do
    if isActivityTransactionUrl(urlMatch) then
      return asActivityDateListUrl(normalizeStatementPeriodUrl(urlMatch))
    end
  end
  return nil
end

local function warmupActivitySession(requestHeaders, refererUrl)
  performGet(
    CONSTANTS.baseUrl .. "/myaccounts/accounts-overview/topNav.go",
    requestHeaders,
    refererUrl
  )
end

local function warmupStatementSession(adxToken, accountDetailsReferer)
  local refererUrl = accountDetailsReferer or
    CONSTANTS.baseUrl .. "/myaccounts/details/card/account-details.go?filter=0&sort=0&order=0"
  local requestHeaders = buildRequestHeaders(refererUrl)
  local statementUrl = buildStatementPageUrl(adxToken)
  local response = performGet(statementUrl, requestHeaders, refererUrl)
  if not response then
    return buildStatementPageUrl(adxToken)
  end

  rememberStatementPageUrl(response, adxToken)
  updateAdxFromResponse(response, adxToken)
  return buildStatementPageUrl(session.adxToken or adxToken)
end

local function ensureAdxInUrl(url, adxToken)
  if not adxToken or url:find("adx=") then
    return url
  end
  if url:find("%?") then
    return url .. "&adx=" .. adxToken
  end
  return url .. "?adx=" .. adxToken
end

local function shouldStopForSince(pageTransactions, sinceTimestamp)
  if not sinceTimestamp or #pageTransactions == 0 then
    return false
  end
  for _, trans in ipairs(pageTransactions) do
    if trans.bookingDate >= sinceTimestamp then
      return false
    end
  end
  return true
end

-- Load Activity periods via Go to: dropdown (stmtFromDateList).
local function loadActivityTransactionsChain(startHtml, adxToken, sinceTimestamp, seenTransactions, allTransactions, requestHeaders, refererUrl, maxPages)
  local currentHtml = startHtml
  local periodLabels = collectActivityPeriodLabels(startHtml)
  local pagesLoaded = 0

  if #periodLabels == 0 then
    mergeTransactions(allTransactions, seenTransactions, parseTransactionsFromPage(startHtml, sinceTimestamp, requestHeaders, refererUrl))
    return 1
  end

  for _, periodLabel in ipairs(periodLabels) do
    if pagesLoaded >= maxPages then
      break
    end

    local periodUrl = findActivityPeriodUrl(currentHtml, periodLabel)
    if not periodUrl then
      periodUrl = extractPreviousPeriodUrl(currentHtml)
    end

    if periodUrl then
      periodUrl = ensureAdxInUrl(periodUrl, adxToken)
      local response = performGet(periodUrl, requestHeaders, refererUrl)
      if response then
        currentHtml = response
        refererUrl = periodUrl
        adxToken = updateAdxFromResponse(response, adxToken)
      end
    end

    local pageTransactions = parseTransactionsFromPage(currentHtml, sinceTimestamp, requestHeaders, refererUrl)
    mergeTransactions(allTransactions, seenTransactions, pageTransactions)
    pagesLoaded = pagesLoaded + 1

    if shouldStopForSince(pageTransactions, sinceTimestamp) then
      break
    end
  end

  return pagesLoaded
end

local function ensureConnection()
  if not connection then
    connection = Connection()
    connection.language = "en-US"
  end
end

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Bank of America"
end

function InitializeSession(protocol, bankCode, username, username2, password, username3)
  connection = Connection()
  connection.language = "en-US"

  if password and password:match("^COOKIE:") then
    return loginWithImportedCookies(password:sub(8))
  end

  -- Normal login not possible due to RSA encryption
  return "Bank of America requires client-side RSA encryption for login.\n\n" ..
         "WORKAROUND - Use Cookie Import Mode:\n" ..
         "1. Login in your browser (www.bankofamerica.com)\n" ..
         "2. Copy cookies from DevTools → Application → Cookies\n" ..
         "3. Use: COOKIE:SMSESSION=...;SSOTOKEN=...;LSESSIONID=...\n\n" ..
         "CRITICAL COOKIES: SMSESSION, SSOTOKEN, LSESSIONID, GSID, CSID, MMID"
end

function loginWithImportedCookies(cookieString)
  local formattedCookies = cookieString:gsub("^%s*(.-)%s*$", "%1")

  if formattedCookies:match(",") and not formattedCookies:match(";") then
    formattedCookies = formattedCookies:gsub("%s*,%s*", "; ")
  end

  if not formattedCookies:match("=") then
    return "Invalid cookie format. Use: name=value;name2=value2"
  end

  local hasSMSession = formattedCookies:match("SMSESSION=[^;]+")

  if not hasSMSession then
    return "ERROR: SMSESSION cookie not found!\n\n" ..
           "This is the MAIN session cookie and is REQUIRED.\n" ..
           "Please copy ALL cookies from browser (including SMSESSION).\n" ..
           "Make sure you are logged in to www.bankofamerica.com first."
  end

  session.cookies = formattedCookies

  local testHeaders = buildRequestHeaders(nil)
  local testResponse = performGet(
    CONSTANTS.baseUrl .. "/myaccounts/details/card/account-details.go",
    testHeaders,
    CONSTANTS.baseUrl .. "/"
  )

  if testResponse then
    local hasAccountData = testResponse:match("Ending in") or
                          testResponse:match("ending in") or
                          testResponse:match("account%-details") or
                          testResponse:match("Account Overview") or
                          testResponse:match("balance")

    local isLoginPage = testResponse:match("Sign In") or
                       testResponse:match("Sign in") or
                       testResponse:match("Log In") or
                       testResponse:match("Log in") or
                       testResponse:match("Enter your user ID") or
                       testResponse:match("Bank of America %- Banking, Credit Cards") or
                       testResponse:match("choose the card that works for you")

    if hasAccountData and not isLoginPage then
      rememberStatementPageUrl(testResponse, session.adxToken)
      updateAdxFromResponse(testResponse, session.adxToken)
      return nil
    end

    if isLoginPage then
      return "SESSION EXPIRED OR INVALID - redirected to login/marketing page.\n\n" ..
             "Your cookies have expired or are incomplete.\n\n" ..
             "TO FIX:\n" ..
             "1. Open browser and go to www.bankofamerica.com\n" ..
             "2. Login with your credentials\n" ..
             "3. After successful login, open DevTools (F12/Cmd+Opt+I)\n" ..
             "4. Go to Application/Storage -> Cookies\n" ..
             "5. Select 'secure.bankofamerica.com'\n" ..
             "6. Copy ALL cookies with their values\n" ..
             "7. Paste into MoneyMoney password field as: COOKIE:SMSESSION=...;SSOTOKEN=...\n\n" ..
             "CRITICAL: Copy cookies immediately after login - they expire quickly!"
    end
  end

  if testStatus and (testStatus:match("403") or testStatus:match("401")) then
    return "SESSION DENIED (HTTP " .. testStatus .. ").\n\n" ..
           "Cookies are invalid or expired. Please copy FRESH cookies from browser after logging in."
  end

  return nil
end

function ListAccounts(knownAccounts)
  if not session.cookies or session.cookies == "" then
    return "No active session. Please use Cookie Import Mode."
  end


  local accounts = {}

  local requestHeaders = buildRequestHeaders(CONSTANTS.baseUrl .. "/")
  local response, status = performGet(
    CONSTANTS.baseUrl .. "/myaccounts/details/card/account-details.go",
    requestHeaders,
    CONSTANTS.baseUrl .. "/"
  )

  if not response then
    return "Failed to fetch accounts: " .. tostring(status)
  end

  rememberStatementPageUrl(response, session.adxToken)
  updateAdxFromResponse(response, session.adxToken)

  if response:match("Sign In") or response:match("Enter your user ID") or
     response:match("Bank of America %- Banking, Credit Cards") then
    return "SESSION EXPIRED - Cookies no longer valid.\n\n" ..
           "Please copy FRESH cookies from your browser:\n" ..
           "1. Login to www.bankofamerica.com\n" ..
           "2. Open DevTools -> Application -> Cookies\n" ..
           "3. Copy all cookies for secure.bankofamerica.com\n" ..
           "4. Update the COOKIE: string in MoneyMoney"
  end

  for accountSection in response:gmatch('TL_NPI_AcctName[^>]*>([\0-\255]-)</span>') do
    local accountName = accountSection:gsub("^%s*", ""):gsub("%s*$", "")
    local maskedNum = accountName:match("%-%s*(%d%d%d%d)%s*$") or accountName:match("(%d%d%d%d)%s*$")
    
    if not maskedNum then
      maskedNum = accountSection:match("%*%*(%d%d%d%d)") or accountSection:match("ending in%s+(%d%d%d%d)")
    end

    if maskedNum then
      local displayName = accountName or ("BoA Account *" .. maskedNum)
      displayName = displayName:gsub("^%s*", ""):gsub("%s*$", "")

      local accountType = AccountTypeGiro
      if displayName:lower():find("card") or displayName:lower():find("credit") or response:find("/card/") then
        accountType = AccountTypeCreditCard
      end

      local alreadyExists = false
      for _, acc in ipairs(accounts) do
        if acc.accountNumber == maskedNum then
          alreadyExists = true
          break
        end
      end

      if not alreadyExists then
        table.insert(accounts, {
          name = displayName,
          accountNumber = maskedNum,
          bankCode = CONSTANTS.bankCode,
          currency = "USD",
          type = accountType,
          attributes = { "statements" }
        })
      end
    end
  end
  
  if #accounts == 0 then
    for num in response:gmatch("Ending in%s+(%d%d%d%d)") do
      local maskedNum = num
      local displayName = "BoA Account *" .. maskedNum
      
      local alreadyExists = false
      for _, acc in ipairs(accounts) do if acc.accountNumber == maskedNum then alreadyExists = true; break end end
      
      if not alreadyExists then
        table.insert(accounts, {
          name = displayName,
          accountNumber = maskedNum,
          bankCode = CONSTANTS.bankCode,
          currency = "USD",
          type = AccountTypeGiro,
          attributes = { "statements" }
        })
      end
    end
  end
  
  -- Final fallback if still no accounts found
  if #accounts == 0 then
    table.insert(accounts, {
      name = "BoA Account (needs manual setup)",
      accountNumber = "0000",
      bankCode = CONSTANTS.bankCode,
      currency = "USD",
      type = AccountTypeGiro,
      attributes = { "statements" }
    })
  end

  return accounts
end

local function stripHtmlTags(fragment)
  return fragment:gsub("<[^>]+>", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeTransactionDetailUrl(urlMatch)
  local url = urlMatch:gsub("&amp;", "&")
  if url:sub(1, 1) == "/" then
    url = CONSTANTS.baseUrl .. url
  elseif not url:find("^http") then
    url = CONSTANTS.baseUrl .. "/" .. url
  end
  return url
end

local function extractTransactionDetailUrl(row)
  local urlMatch = row:match('rel="([^"]*transaction%-details%.go[^"]*)"')
  if urlMatch then
    return normalizeTransactionDetailUrl(urlMatch)
  end
  return nil
end

local function parseTransactionDetailsHtml(html)
  if not html or html == "" then
    return nil
  end

  local details = {}
  local tableHtml = html:match('class="trans%-expanded%-details"[^>]*>([\0-\255]-)</table>') or html

  for row in tableHtml:gmatch("<tr[^>]*>([\0-\255]-)</tr>") do
    if row:find("first-expanded-cell", 1, true) and row:find("second-expanded-cell", 1, true) then
      local label = row:match("first%-expanded%-cell[^>]*>([\0-\255]-)</t[dh]>")
      local value = row:match("second%-expanded%-cell[^>]*>([\0-\255]-)</t[dh]>")
      if label and value then
        label = stripHtmlTags(label):gsub(":$", "")
        value = stripHtmlTags(value)
        if label ~= "" and value ~= "" then
          details[label] = value
        end
      end
    end
  end

  local merchant = html:match('class="lblMerchantNameVal">([^<]+)<')
  if merchant and merchant ~= "" then
    details["Merchant Name"] = merchant:gsub("^%s+", ""):gsub("%s+$", "")
  end

  local category = html:match('class="lblCategoryName">([^<]+)<')
  if category and category ~= "" then
    details["Transaction Category"] = category:gsub("^%s+", ""):gsub("%s+$", "")
  end

  if next(details) == nil then
    return nil
  end
  return details
end

local function applyTransactionDetails(trans, details)
  local merchant = details["Merchant Name"]
  if merchant and merchant ~= "" then
    trans.name = merchant
  end

  local transType = details["Transaction type"]
  if transType and transType ~= "" then
    trans.bookingText = transType
  end

  local refNum = details["Reference number"]
  if refNum and refNum ~= "" then
    trans.endToEndReference = refNum
  end

  local purposeLines = {}
  if merchant and merchant ~= "" then
    table.insert(purposeLines, merchant)
  elseif trans.purpose and trans.purpose ~= "" then
    table.insert(purposeLines, trans.purpose)
  end

  if details["Transaction Category"] then
    table.insert(purposeLines, "Category: " .. details["Transaction Category"])
  end
  if details["Card type"] then
    table.insert(purposeLines, "Card: " .. details["Card type"])
  end
  if details["Online Purchase"] then
    table.insert(purposeLines, "Online purchase: " .. details["Online Purchase"])
  end
  if refNum and refNum ~= "" then
    table.insert(purposeLines, "Reference: " .. refNum)
  end

  if #purposeLines > 0 then
    trans.purpose = table.concat(purposeLines, "\n")
  end
end

local function enrichTransactionsWithDetails(transactions, requestHeaders, refererUrl)
  if not refererUrl or refererUrl == "" then
    return
  end

  local detailHeaders = buildAjaxPostHeaders(refererUrl)
  for _, trans in ipairs(transactions) do
    local detailUrl = trans._detailUrl
    trans._detailUrl = nil
    if detailUrl then
      local detailHtml = performPost(detailUrl, "", nil, detailHeaders, refererUrl)
      if detailHtml and detailHtml ~= "" then
        local details = parseTransactionDetailsHtml(detailHtml)
        if details then
          applyTransactionDetails(trans, details)
        end
      end
    end
  end
end

local function parseTransactionRow(row, sinceTimestamp)
  local rowLower = row:lower()

  local isHeaderRow = rowLower:find('<th') or rowLower:find('trans%-thead%-wrap') or rowLower:find('icon%-legend%-head')
  local isBalanceRow = rowLower:find('beginning%-balance%-row') or rowLower:find('beginning%-balance%-msg')
  local isNoTransRow = rowLower:find('no%-trans%-from%-filt')
  if isHeaderRow or isBalanceRow or isNoTransRow then
    return nil
  end

  local hasTransDesc = rowLower:find('trans%-desc') or row:find('TL_NPI_TransDesc') or rowLower:find('fmt%-txn%-desc')
  local hasTransAmount = rowLower:find('trans%-amount') or row:find('TL_NPI_Amt') or rowLower:find('ta%-rt')
  local hasIconType = rowLower:find('icon%-type%-')
  local hasDateCell = rowLower:find('trans%-date%-cell') or rowLower:find('date%-td')
  if not hasTransDesc and not hasTransAmount and not hasIconType and not hasDateCell then
    return nil
  end

  local dateStr = nil
  local mm, dd, yyyy = row:match('[Tt]ransaction [Dd]ate:%s*(%d%d)/(%d%d)/(%d%d%d%d)')
  if mm and dd and yyyy then
    dateStr = mm .. '/' .. dd .. '/' .. yyyy
  end
  if not dateStr then
    mm, dd, yyyy = row:match('>(%d%d)/(%d%d)/(%d%d%d%d)<')
    if mm and dd and yyyy then
      dateStr = mm .. '/' .. dd .. '/' .. yyyy
    end
  end
  if not dateStr then
    local dateStart = rowLower:find('trans%-date%-cell') or rowLower:find('date%-td')
    if dateStart then
      local dateCellEnd = rowLower:find('</td>', dateStart) or #row
      local dateCell = row:sub(dateStart, dateCellEnd)
      mm, dd, yyyy = dateCell:match('(%d%d)/(%d%d)/(%d%d%d%d)')
      if mm and dd and yyyy then
        dateStr = mm .. '/' .. dd .. '/' .. yyyy
      elseif dateCell:lower():match('pending') then
        dateStr = 'Pending'
      end
    end
  end

  local desc = row:match('alt="Expand transaction for Transaction date: %d%d/%d%d/%d%d%d%d%s+([^"]+)"')
  if desc then
    desc = desc:gsub("^%s*", ""):gsub("%s*$", "")
  end

  if not desc or desc == "" then
    desc = row:match('expand%-trans%-from%-desc[^>]*>.-%</span>%s*([^<]+)<')
    if desc then
      desc = desc:gsub("^%s*", ""):gsub("%s*$", "")
    end
  end

  if not desc or desc == "" then
    local descStart = rowLower:find('trans%-desc%-cell') or row:find('TL_NPI_TransDesc') or rowLower:find('fmt%-txn%-desc')
    if descStart then
      local descSection = row:sub(descStart, descStart + 1000)
      for text in descSection:gmatch('>([^<]+)<') do
        local trimmed = text:gsub("^%s*", ""):gsub("%s*$", "")
        trimmed = trimmed:gsub("Expand transaction for Transaction date: %d%d/%d%d/%d%d%d%d%s*", "")
        if trimmed ~= "" and not trimmed:find("Expand transaction") and not trimmed:find("Type Temporary Transactions") and not trimmed:find("Type&nbsp;") then
          desc = trimmed
          break
        end
      end
    end
  end

  local amountStr = nil
  local amtStart = rowLower:find('trans%-amount%-cell') or row:find('TL_NPI_Amt') or rowLower:find('ta%-rt')
  if amtStart then
    local amountSection = row:sub(amtStart, amtStart + 200)
    amountStr = amountSection:match('>%s*([%-+%$]?%$?[%d%.,]+)%s*<') or
                amountSection:match('>%s*(%-%$[%d%.,]+)%s*<') or
                amountSection:match('>%s*(%$[%d%.,]+)%s*<')
  end

  if not desc or desc == "" or not amountStr then
    return nil
  end

  desc = desc:gsub("^%s*", ""):gsub("%s*$", "")

  local amount = 0
  local isNegativeInHtml = amountStr:match("^%s*%-") or amountStr:match("%-%$")
  local cleanAmountStr = amountStr:gsub("%$", ""):gsub(",", "")
  amount = tonumber((cleanAmountStr)) or 0

  local bookingDate = os.time()
  local valutaDate = os.time()

  if dateStr then
    dateStr = dateStr:gsub("^%s*", ""):gsub("%s*$", "")
    if dateStr == "Pending" or dateStr:lower():match('pending') then
      local now = os.date("*t")
      bookingDate = os.time({year = now.year, month = now.month, day = now.day, hour = 0, min = 0, sec = 0})
      valutaDate = bookingDate
    else
      mm, dd, yyyy = dateStr:match("(%d%d)/(%d%d)/(%d%d%d%d)")
      if mm and dd and yyyy then
        bookingDate = os.time({year = tonumber(yyyy), month = tonumber(mm), day = tonumber(dd)})
        valutaDate = bookingDate
      end
    end
  end

  local transType = nil
  local relStart = rowLower:find('rel="', rowLower:find('icon%-type'))
  if relStart then
    local typeStart = relStart + 5
    local typeEnd = row:find('"', typeStart)
    if typeEnd then
      transType = row:sub(typeStart, typeEnd - 1)
    end
  end
  if not transType or transType == "" then
    transType = row:match('icon%-type%-([%w%-]+)')
  end

  local isPurchase = (transType == "CH" or transType == "CR" or transType == "DC" or
                    transType == "TT" or transType == "FE" or transType == "WD" or
                    transType == "P" or transType == "Purchase" or transType == "purchase" or
                    transType == "generic-debit" or transType == "withdrawal" or transType == "bank-charge" or
                    transType == "purchase")
  local isPayment = (transType == "PY" or transType == "PM" or transType == "RC" or
                   transType == "OP" or transType == "Payment" or transType == "payment" or
                   transType == "generic-credit" or transType == "deposit-recur" or transType == "payment-recur" or
                   transType == "payment")

  if isPurchase and amount > 0 then
    amount = -amount
  elseif isPayment and amount < 0 then
    amount = math.abs(amount)
  elseif isNegativeInHtml then
    amount = math.abs(amount)
  else
    amount = -math.abs(amount)
  end

  if sinceTimestamp and bookingDate < sinceTimestamp then
    if dateStr ~= "Pending" and not dateStr:lower():match('pending') then
      return nil
    end
  end

  local detailUrl = extractTransactionDetailUrl(row)

  return {
    bookingDate = bookingDate,
    valutaDate = valutaDate,
    purpose = desc,
    amount = amount,
    currency = "USD",
    _detailUrl = detailUrl
  }
end

function parseTransactionsFromPage(response, sinceTimestamp, requestHeaders, refererUrl)
  local transactions = {}
  local seen = {}

  local function addTransactionFromRow(row)
    local trans = parseTransactionRow(row, sinceTimestamp)
    if trans then
      local key = trans.bookingDate .. "|" .. trans.purpose .. "|" .. tostring(trans.amount)
      if not seen[key] then
        seen[key] = true
        table.insert(transactions, trans)
      end
    end
  end

  local tbodyStart = response:lower():find('<tbody class="trans%-tbody%-wrap"')
  if tbodyStart then
    local tbodyEnd = response:lower():find("</tbody>", tbodyStart)
    if tbodyEnd then
      local tbody = response:sub(tbodyStart, tbodyEnd + 8)
      local searchPos = 1
      while true do
        local trStart, trStartEnd = tbody:lower():find("<tr[^>]*>", searchPos)
        if not trStart then
          break
        end
        local trEnd = tbody:lower():find("</tr>", trStartEnd + 1)
        if not trEnd then
          break
        end
        addTransactionFromRow(tbody:sub(trStart, trEnd + 5))
        searchPos = trEnd + 5
      end
    end
  end

  if #transactions == 0 then
    local pos = 1
    while true do
      local markerPos = response:lower():find("trans%-first%-row", pos)
      if not markerPos then
        break
      end

      local trStart = response:lower():find("<tr", math.max(1, markerPos - 400))
      if not trStart then
        pos = markerPos + 1
      else
        local trEnd = response:lower():find("</tr>", markerPos)
        if not trEnd then
          break
        end
        addTransactionFromRow(response:sub(trStart, trEnd + 5))
        pos = trEnd + 5
      end
    end
  end


  if requestHeaders and refererUrl and #transactions > 0 then
    enrichTransactionsWithDetails(transactions, requestHeaders, refererUrl)
  end

  return transactions
end

function RefreshAccount(account, since)
  if not account or not account.accountNumber then
    return { balance = 0, transactions = {} }
  end

  if not session.cookies or session.cookies == "" then
    return { balance = 0, transactions = {} }
  end

  local sinceTimestamp = since

  local allTransactions = {}
  local seenTransactions = {}
  local maxPages = 24
  local currentUrl = CONSTANTS.baseUrl .. "/myaccounts/details/card/account-details.go"
  local refererUrl = CONSTANTS.baseUrl .. "/myaccounts/accounts-overview/topNav.go"
  local requestHeaders = buildRequestHeaders(refererUrl)

  warmupActivitySession(requestHeaders, CONSTANTS.baseUrl .. "/")

  local firstPageResponse = performGet(
    currentUrl .. "?filter=0&sort=0&order=0",
    requestHeaders,
    refererUrl
  )
  
  if not firstPageResponse then
    return { balance = 0, transactions = {} }
  end

  rememberStatementPageUrl(firstPageResponse, session.adxToken)

  local balance = 0
  local balStr = firstPageResponse:match('[Ss]tatement [Bb]alance:.-TL_NPI_L1">%$?([%d%.,]+)') or
                 firstPageResponse:match('[Cc]urrent [Bb]alance:.-TL_NPI_L1">%$?([%d%.,]+)') or
                 firstPageResponse:match('[Tt]otal [Cc]redit [Aa]vailable:.-TL_NPI_L1">%$?([%d%.,]+)')
  
  if balStr then
    balance = tonumber((balStr:gsub(",", ""))) or 0
    if account.type == AccountTypeCreditCard and firstPageResponse:lower():find("statement balance") then
      balance = -balance
    end
  end

  local adxToken = firstPageResponse:match('adx=["\']?([0-9a-f]+)') or 
                   firstPageResponse:match('["\']adx["\']%s*[:=]%s*["\']?([0-9a-f]+)')
  if adxToken then
    session.adxToken = adxToken
  end

  refererUrl = currentUrl .. "?filter=0&sort=0&order=0"

  loadActivityTransactionsChain(
    firstPageResponse,
    adxToken,
    sinceTimestamp,
    seenTransactions,
    allTransactions,
    requestHeaders,
    refererUrl,
    maxPages
  )

  return { balance = balance, transactions = allTransactions }
end

function EndSession()
  -- Do not call signoff here: MoneyMoney invokes GetAvailableStatements/GetStatement
  -- after EndSession(), and signoff can invalidate the statements API session.
end

local function resolveAdxToken(adxToken)
  if adxToken and adxToken ~= "" then
    return adxToken
  end
  if session.adxToken and session.adxToken ~= "" then
    return session.adxToken
  end

  local requestHeaders = buildRequestHeaders(CONSTANTS.baseUrl .. "/")
  local response = performGet(
    CONSTANTS.baseUrl .. "/myaccounts/details/card/account-details.go?filter=0&sort=0&order=0",
    requestHeaders,
    CONSTANTS.baseUrl .. "/"
  )

  if not response then
    return nil
  end

  rememberStatementPageUrl(response, adxToken)
  adxToken = updateAdxFromResponse(response, adxToken)
  return adxToken
end

local function appendParsedStatement(statements, seenDocIds, docId, docName, dateStr, adxToken, sinceTimestamp)
  local y, m, d = dateStr:match("(%d%d%d%d)-(%d%d)-(%d%d)")
  local bookingDate = os.time()
  if y and m and d then
    bookingDate = os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d)})
  end

  if sinceTimestamp and bookingDate < sinceTimestamp then
    return
  end
  if seenDocIds[docId] then
    return
  end

  seenDocIds[docId] = true
  table.insert(statements, {
    id = docId .. "|" .. adxToken,
    type = "Statement",
    name = docName,
    periodEnd = os.date("%Y-%m-%d", bookingDate),
    generatedDate = os.date("%Y-%m-%d", bookingDate),
    formats = "PDF"
  })
end

local function parseStatementsFromGatherResponse(jsonResponse, adxToken, sinceTimestamp, seenDocIds, statements)
  if not jsonResponse or jsonResponse == "" then
    return
  end

  local documentList = jsonResponse:match('"documentList"%s*:%s*(%b[])')
  local searchText = documentList or jsonResponse
  for docId, docName, dateStr in searchText:gmatch('"docId"%s*:%s*"([^"]+)"[^}]-"docDisplayName"%s*:%s*"([^"]+)"[^}]-"date"%s*:%s*"([^"]+)"') do
    appendParsedStatement(statements, seenDocIds, docId, docName, dateStr, adxToken, sinceTimestamp)
  end
end

function fetchStatementDocuments(adxToken, sinceTimestamp)
  local statements = {}
  local seenDocIds = {}

  adxToken = resolveAdxToken(adxToken)
  if not adxToken then
    return statements
  end


  local accountDetailsReferer = CONSTANTS.baseUrl .. "/myaccounts/details/card/account-details.go?filter=0&sort=0&order=0"
  local statementReferer = warmupStatementSession(adxToken, accountDetailsReferer)
  adxToken = session.adxToken or adxToken

  local gatherUrl = CONSTANTS.baseUrl .. "/ogateway/dsviewdocuments/omni/statements/v1/gatherDocuments"
  local postHeaders = buildJsonPostHeaders(statementReferer)

  local currentYear = os.date("%Y")
  local bootstrapData = '{"adx":"' .. adxToken .. '","year":"' .. currentYear .. '","docCategoryId":"0000"}'
  local bootstrapResponse = performPost(gatherUrl, bootstrapData, "application/json; charset=UTF-8", postHeaders, statementReferer)
  if bootstrapResponse and bootstrapResponse ~= "" then
    parseStatementsFromGatherResponse(bootstrapResponse, adxToken, sinceTimestamp, seenDocIds, statements)
  end

  local years = {currentYear, tostring(tonumber(currentYear) - 1)}
  for _, year in ipairs(years) do
    local postData = '{"year":"' .. year .. '","adx":"' .. adxToken .. '","docCategoryId":"DISPFLD001","lang":"en-US"}'
    local stmtResponse = performPost(gatherUrl, postData, "application/json; charset=UTF-8", postHeaders, statementReferer)

    if stmtResponse and stmtResponse ~= "" then
      parseStatementsFromGatherResponse(stmtResponse, adxToken, sinceTimestamp, seenDocIds, statements)
    end
  end

  return statements
end

local function buildKnownIdentifierSet(knownIdentifiers)
  local knownSet = {}
  if type(knownIdentifiers) ~= "table" then
    return knownSet
  end

  for key, value in pairs(knownIdentifiers) do
    if type(key) == "number" and type(value) == "string" then
      knownSet[value] = true
    elseif type(key) == "string" then
      knownSet[key] = true
    end
  end
  return knownSet
end

local function parseStatementCreationDate(periodEnd)
  if not periodEnd then
    return os.time()
  end
  local y, m, d = periodEnd:match("(%d%d%d%d)-(%d%d)-(%d%d)")
  if y and m and d then
    return os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d)})
  end
  return os.time()
end

local function downloadStatementPdf(docId, adxToken)
  adxToken = resolveAdxToken(adxToken)
  if not docId or not adxToken then
    return nil, "missing document information"
  end

  local accountDetailsReferer = CONSTANTS.baseUrl .. "/myaccounts/details/card/account-details.go?filter=0&sort=0&order=0"
  local statementReferer = warmupStatementSession(adxToken, accountDetailsReferer)
  adxToken = session.adxToken or adxToken
  local postHeaders = buildJsonPostHeaders(statementReferer)

  local downloadUrl = CONSTANTS.baseUrl .. "/ogateway/dsviewdocuments/omni/statements/v1/docViewDownload" ..
    "?adx=" .. MM.urlencode(adxToken) ..
    "&documentId=" .. MM.urlencode(docId) ..
    "&adaDocumentFlag=N" ..
    "&menuFlag=download" ..
    "&request_locale=en-US"

  local pdfHeaders = buildPdfGetHeaders(statementReferer)
  local response, status, mimeType = performGet(downloadUrl, pdfHeaders, statementReferer)

  if response and (response:sub(1, 4) == "%PDF" or (mimeType and mimeType:lower():find("pdf"))) then
    return response, nil
  end

  local postData = '{"adx":"' .. adxToken .. '","docId":"' .. docId .. '","docCategoryId":"DISPFLD001"}'
  response, status, mimeType = performPost(
    CONSTANTS.baseUrl .. "/ogateway/dsviewdocuments/omni/statements/v1/retrieveDocument",
    postData,
    "application/json; charset=UTF-8",
    postHeaders,
    statementReferer
  )

  if response then
    if response:sub(1, 4) == "%PDF" or (mimeType and mimeType:lower():find("pdf")) then
      return response, nil
    end
    local pdfBase64 = response:match('"pdfData"%s*:%s*"([^"]+)"') or response:match('"documentData"%s*:%s*"([^"]+)"')
    if pdfBase64 and MM.base64Decode then
      local pdf = MM.base64Decode(pdfBase64)
      if pdf and pdf:sub(1, 4) == "%PDF" then
        return pdf, nil
      end
    end
  end

  if response and (response:sub(1, 200):find("html") or response:sub(1, 200):find("<!DOCTYPE")) then
    return nil, "server returned HTML instead of PDF"
  end

  return nil, "unexpected response (status " .. tostring(status) .. ")"
end

function FetchStatements(accounts, knownIdentifiers)
  ensureConnection()

  if not session.cookies or session.cookies == "" then
    return "No active session cookies for statement download"
  end

  local knownSet = buildKnownIdentifierSet(knownIdentifiers)
  local downloadedStatements = {}
  local availableStatements = fetchStatementDocuments(session.adxToken, nil)

  for _, statementMeta in ipairs(availableStatements) do
    local identifier = statementMeta.id or ((statementMeta.name or "statement") .. "|" .. (statementMeta.periodEnd or ""))
    if not knownSet[identifier] then
      local docId, adxToken = identifier:match("([^|]+)|(.+)")
      local pdf = downloadStatementPdf(docId, adxToken)
      if pdf then
        table.insert(downloadedStatements, {
          creationDate = parseStatementCreationDate(statementMeta.periodEnd),
          name = statementMeta.name or "Statement",
          identifier = identifier,
          pdf = pdf,
          filename = (statementMeta.name or "statement"):gsub("[^%w%-_ ]", "") .. ".pdf"
        })
      end
    end
  end

  return { statements = downloadedStatements }
end

function GetAvailableStatements(account, since)
  ensureConnection()

  if not session.cookies or session.cookies == "" then
    return nil
  end

  local sinceTimestamp = since
  local statements = fetchStatementDocuments(session.adxToken, sinceTimestamp)

  if #statements == 0 then
    return {}
  end

  return statements
end

function GetStatement(account, statementId)
  ensureConnection()

  if not session.cookies or session.cookies == "" then
    return "Could not download statement: session expired"
  end

  local docId, adxToken = statementId:match("([^|]+)|(.+)")
  if not docId then
    docId = statementId
  end

  local pdf, err = downloadStatementPdf(docId, adxToken)
  if pdf then
    return pdf
  end

  return "Could not download statement: " .. tostring(err)
end

function DownloadStatement(account, statement)
  local statementId = statement
  if type(statement) == "table" then
    statementId = statement.id or statement.statementId
  end
  return GetStatement(account, statementId)
end

-- SIGNATURE: MC4CFQCbwcy5iiv/AJGS3E85IYCIXkbltgIVAIHAMbH4w6H5GLVc1KNxCJkhTYyG
