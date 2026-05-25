--
-- Presidential Bank — MoneyMoney Web Banking Extension
-- https://www.presidentialpcbanking.com
-- Dokumentation: docs/LUA-EXTENSIONS.md
-- API: https://moneymoney.app/api/webbanking/
--

WebBanking{
  version     = 1.00,
  url         = "https://www.presidentialpcbanking.com",
  services    = {"Presidential Bank"},
  description = "Presidential Bank - Supports Normal Login (MFA) and Cookie Import Mode"
}

local CONSTANTS = {
  baseUrl = "https://www.presidentialpcbanking.com",
  authApi = "https://www.presidentialpcbanking.com/auth-olb/live/v1",
  acctsApi = "https://www.presidentialpcbanking.com/accts-olb/live/v1",
  bankCode = "255073345"
}

local connection
local session = {}

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Presidential Bank"
end

function InitializeSession2(protocol, bankCode, step, credentials, interactive)
  connection = Connection()
  connection.language = "en-US"
  connection.useragent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"

  if step == 1 then
    return handleLoginStep1(credentials)
  end

  -- Folge-Steps state-basiert dispatchen, damit Retries (z.B. falscher
  -- OTP-Code oder ungueltige Methodenauswahl) im richtigen Handler landen.
  -- MoneyMoney inkrementiert step bei jedem Re-Prompt; ein step-basierter
  -- Dispatcher wuerde Retries faelschlich zum Cookie-Import umleiten.
  if session.waitingForMethodSelection then
    return handleMethodSelection(credentials[1])
  end
  if session.waitingForMfaCode then
    return verifyMfaCode(credentials[1])
  end
  if session.waitingForCookieImport then
    return handleCookieImportStep(credentials)
  end

  return LoginFailed
end

function handleLoginStep1(credentials)
  local username = credentials[1]
  local password = credentials[2]

  if password and password:match("^COOKIE:") then
    return loginWithImportedCookies(password:sub(8))
  end

  MM.printStatus("Logging in to Presidential Bank...")

  -- POST credentials to external-login
  local loginFormData = "testcookie=false&testjs=true&dscheck=1&userid=" .. MM.urlencode(username) .. "&password=" .. MM.urlencode(password)
  local externalResponse = connection:request(
    "POST",
    CONSTANTS.authApi .. "/external-login",
    loginFormData,
    "application/x-www-form-urlencoded",
    {
      ["Accept"] = "application/json, text/plain, */*",
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["Origin"] = CONSTANTS.baseUrl,
      ["Referer"] = CONSTANTS.baseUrl .. "/dbank/live/app/external-login"
    }
  )

  if not externalResponse then
    return LoginFailed
  end

  -- Update visible cookies
  local newCookies = connection:getCookies()
  if newCookies and newCookies:match("SESSION") then
    session.cookies = newCookies
  end

  -- Check for error response
  local extLoginData = parseJson(externalResponse)
  if extLoginData and (extLoginData.targetView == "error" or extLoginData.errorMessage) then
    return LoginFailed
  end

  -- POST to login/redirect
  local redirectResponse = connection:request(
    "POST",
    CONSTANTS.authApi .. "/login/redirect?mfaLSO=",
    "{}",
    "application/json",
    {
      ["Accept"] = "application/json",
      ["Content-Type"] = "application/json",
      ["Origin"] = CONSTANTS.baseUrl,
      ["Referer"] = CONSTANTS.baseUrl .. "/dbank/live/app/external-login",
      ["Cookie"] = session.cookies
    }
  )

  if not redirectResponse then
    return LoginFailed
  end

  -- Update visible cookies
  local newCookies = connection:getCookies()
  if newCookies and newCookies:match("SESSION") then
    session.cookies = newCookies
  end

  -- Check if we have the rftoken cookie (HttpOnly - will be empty)
  -- This is expected to fail - rftoken is HttpOnly and not accessible
  if not session.cookies or not session.cookies:match("rftoken") then
    MM.printStatus("Note: rftoken (HttpOnly cookie) is not accessible. MFA flow will fail after code entry.")
    MM.printStatus("WORKAROUND: Use Cookie Import Mode instead.")
  end

  return getMfaConfig()
end

function getMfaConfig()
  local mfaConfigResponse = connection:request("GET", CONSTANTS.authApi .. "/mfa/config", nil, nil, {
    ["Accept"] = "application/json",
    ["Referer"] = CONSTANTS.baseUrl .. "/dbank/live/app/mfa",
    ["Cookie"] = session.cookies
  })

  if not mfaConfigResponse then
    return LoginFailed
  end

  -- Only update if we got visible cookies (preserve HttpOnly cookies)
  local newCookies = connection:getCookies()
  if newCookies and newCookies:match("SESSION") then
    session.cookies = newCookies
  end

  local mfaData = parseJson(mfaConfigResponse)

  if not mfaData then
    return LoginFailed
  end

  session.mfaConfig = mfaData
  session.csrfToken = extractCsrfToken(mfaData)
  session.mfaMethods = extractMfaMethods(mfaData)

  if #session.mfaMethods == 0 then
    session.waitingForMfaCode = true
    return mfaCodeChallenge(nil)
  end

  session.waitingForMethodSelection = true
  return buildMfaSelectionChallenge()
end

function extractCsrfToken(mfaData)
  if mfaData.pageProps and mfaData.pageProps.CSRFToken then
    return mfaData.pageProps.CSRFToken
  elseif mfaData.targetData and mfaData.targetData.CSRFToken then
    return mfaData.targetData.CSRFToken
  elseif mfaData.globalEnvProps and mfaData.globalEnvProps.globalIFS then
    return mfaData.globalEnvProps.globalIFS.guid
  end
  return nil
end

function extractMfaMethods(mfaData)
  local methods = {}

  if not (mfaData.targetData and mfaData.targetData.destinations) then
    return methods
  end

  local destinations = mfaData.targetData.destinations
  if type(destinations) == "string" then
    destinations = parseJson(destinations) or {}
  end

  if type(destinations) ~= "table" then
    return methods
  end

  for _, dest in ipairs(destinations) do
    if dest.activated then
      local method = buildMfaMethod(dest)
      if method then
        table.insert(methods, method)
      end
    end
  end

  return methods
end

function buildMfaMethod(dest)
  local method = {
    id = dest.id and dest.id.value,
    protocol = dest.protocol,
    contactInfo = dest.contactInfo or ""
  }

  local protocolMap = {
    TOTP = { name = "Authenticator App (TOTP)", type = "totp" },
    SMS = { name = "Text me at " .. method.contactInfo, type = "sms" },
    VOICE = { name = "Call me at " .. method.contactInfo, type = "voice" },
    EMAIL = { name = "Email me at " .. method.contactInfo, type = "email" }
  }

  local mapped = protocolMap[dest.protocol]
  if not mapped then
    return nil
  end

  method.name = mapped.name
  method.type = mapped.type
  return method
end

-- SSOT fuer Selection-Challenge; optional mit Prefix-Text fuer Retry-Fall.
function buildMfaSelectionChallenge(prefix)
  local options = {}
  for i, method in ipairs(session.mfaMethods) do
    table.insert(options, i .. ". " .. method.name)
  end
  local body = "Select verification method:\n\n" .. table.concat(options, "\n") .. "\n\nEnter number:"
  return {
    title = "Two-Factor Authentication",
    challenge = (prefix and prefix .. "\n\n" or "") .. body,
    label = "Option (1-" .. #session.mfaMethods .. ")"
  }
end

-- SSOT fuer Code-Eingabe-Challenge (TOTP oder per Kanal versendet); optional
-- mit Prefix-Text fuer Retry nach abgelehntem Code. MoneyMoney ruft
-- InitializeSession2 mit step=N+1 erneut auf, wenn statt eines Fehler-Strings
-- ein {title, challenge, label}-Table zurueckgegeben wird (Web Banking API:
-- "Anmeldung mit Zwei-Faktor-Authentifizierung").
function mfaCodeChallenge(method, prefix)
  local isPushed = method and method.type and method.type ~= "totp"
  local body
  if isPushed then
    body = "A code has been sent to " .. method.name .. ".\n\nEnter the code:"
  else
    body = "Enter the 6-digit code from your Authenticator app:"
  end
  return {
    title = "Two-Factor Authentication",
    challenge = (prefix and prefix .. "\n\n" or "") .. body,
    label = isPushed and "Verification Code" or "TOTP Code"
  }
end

function handleMethodSelection(userInput)
  if not session.cookies or session.cookies == "" then
    session.waitingForMethodSelection = false
    return "MFA verification failed: No active session"
  end

  local methodIndex = tonumber(userInput)
  if not methodIndex or methodIndex < 1 or methodIndex > #session.mfaMethods then
    -- Selection-State erhalten, User soll erneut waehlen.
    return buildMfaSelectionChallenge(
      "Invalid selection. Please enter a number between 1 and " .. #session.mfaMethods .. "."
    )
  end

  session.selectedMfaMethod = session.mfaMethods[methodIndex]
  session.waitingForMethodSelection = false
  session.waitingForMfaCode = true

  if session.selectedMfaMethod.type ~= "totp" then
    requestVerificationCode(session.selectedMfaMethod)
  end

  return mfaCodeChallenge(session.selectedMfaMethod)
end

function requestVerificationCode(method)
  session.csrfToken = session.csrfToken or extractCsrfTokenFromCookies(session.cookies) or ""

  local body = JSON():set({
    csrftoken = session.csrfToken,
    destId = method.id,
    protocol = method.protocol
  }):json()

  connection:request(
    "POST",
    CONSTANTS.authApi .. "/mfa/sendcode?displayMethod=" .. method.protocol,
    body,
    "application/json",
    buildApiHeaders(session.cookies)
  )
end

function verifyMfaCode(code)
  if not session.cookies or session.cookies == "" then
    session.waitingForMfaCode = false
    return "MFA verification failed: No active session"
  end

  local method = session.selectedMfaMethod

  -- Format-Vorpruefung: leere/nicht-numerische Eingabe -> Retry-Challenge.
  if not code or not code:match("^%s*%d+%s*$") then
    return mfaCodeChallenge(method, "Invalid code (digits only). Please try again.")
  end
  code = code:gsub("^%s*(.-)%s*$", "%1")

  session.csrfToken = session.csrfToken or extractCsrfTokenFromCookies(session.cookies) or ""

  local submitUrl, bodyTable
  if method and method.type ~= "totp" then
    submitUrl = CONSTANTS.authApi .. "/mfa/submit?displayMethod=" .. method.protocol
    bodyTable = { csrftoken = session.csrfToken, otp = code, destId = method.id }
  else
    submitUrl = CONSTANTS.authApi .. "/mfa/submit?displayMethod=TOTP&type=OTP"
    local totpId = method and method.id or findTotpId()
    bodyTable = { csrftoken = session.csrfToken, otp = code, destId = totpId or "" }
  end

  local body = JSON():set(bodyTable):json()
  local mfaResponse = connection:request("POST", submitUrl, body, "application/json", buildApiHeaders(session.cookies))

  if not mfaResponse then
    session.waitingForMfaCode = false
    return "MFA verification failed: No response from server"
  end

  local newCookies = connection:getCookies()
  if newCookies and newCookies:match("SESSION") then
    session.cookies = newCookies
  end

  if not isMfaSuccess(mfaResponse) then
    -- Falscher Code: MFA-State erhalten, neuen CSRF-Token aus Response
    -- uebernehmen falls vorhanden (manche Server rotieren ihn nach jedem
    -- Submit) und Retry-Challenge zurueck, statt Login abzubrechen.
    local data = parseJson(mfaResponse)
    if data then
      local freshCsrf = extractCsrfToken(data)
      if freshCsrf then session.csrfToken = freshCsrf end
    end
    return mfaCodeChallenge(method, "Invalid code. Please try again.")
  end

  session.waitingForMfaCode = false
  return finalizeLogin()
end

function findTotpId()
  if not session.mfaMethods then
    return nil
  end
  for _, m in ipairs(session.mfaMethods) do
    if m.type == "totp" then
      return m.id
    end
  end
  return nil
end

function isMfaSuccess(response)
  local data = parseJson(response)
  if not data then
    return false
  end

  if data.errorCode then
    return false
  end

  if data.targetView == "success" or data.targetView == "redirect" then
    return true
  end

  if data.result then
    local result = parseJson(data.result)
    if result and result.success == "success" then
      return true
    end
  end

  return false
end

function finalizeLogin()
  -- Call login/update to finalize (may fail due to HttpOnly cookies, but session might still be valid)
  connection:request("POST", CONSTANTS.authApi .. "/login/update", "", "application/json", {
    ["Accept"] = "application/json",
    ["Origin"] = CONSTANTS.baseUrl,
    ["Referer"] = CONSTANTS.baseUrl .. "/dbank/live/app/mfa",
    ["Cookie"] = session.cookies
  })

  -- Update cookies - only if we actually got cookies back (HttpOnly cookies won't be visible)
  local newCookies = connection:getCookies()
  if newCookies and newCookies:match("SESSION") then
    session.cookies = newCookies
  end

  -- Validate session with user/authtoken
  connection:request("GET", CONSTANTS.authApi .. "/user/authtoken", nil, nil, {
    ["Accept"] = "application/json",
    ["Referer"] = CONSTANTS.baseUrl .. "/dbank/live/app/home",
    ["Cookie"] = session.cookies
  })

  -- Update cookies - only if we actually got cookies back
  newCookies = connection:getCookies()
  if newCookies and newCookies:match("SESSION") then
    session.cookies = newCookies
  end

  -- Check if we have valid session cookies (SESSION_TOKEN)
  if not session.cookies:match("SESSION_TOKEN") then
    return LoginFailed
  end

  -- Check if we have rftoken (required for API access)
  if not extractCookieValue(session.cookies, "rftoken") then
    -- WORKAROUND: After MFA, the bank creates a new session with HttpOnly cookies
    -- that we cannot access. Inform user about Cookie Import Mode.
    return "Login successful, but HttpOnly cookie (rftoken) is required for API access.\n\nWORKAROUND:\n1. Login in your browser\n2. Copy cookies from DevTools → Network\n3. Use: COOKIE:SESSION_TOKEN=...;rftoken=..."
  end

  MM.printStatus("Login successful - SESSION_TOKEN and rftoken received")
  return nil
end

function ListAccounts(knownAccounts)
  if not hasValidSession() then
    return "No active session"
  end

  -- Use /history endpoint with rftoken as URL parameter (like browser does)
  -- The web app uses /history, not /accounts for account listing
  local acctUrl = CONSTANTS.acctsApi .. "/history?allowAccountsCall=true&getExportAccountNums=true&getxuseraccts&locationId&pageId=history&transfers_display_xuser_accounts"
  if session.rftoken then
    acctUrl = acctUrl .. "&rftoken=" .. session.rftoken
  end

  local response = connection:request("GET", acctUrl, nil, nil, buildRequestHeaders())

  if not response then
    return "Account discovery failed"
  end

  updateCookies()

  local data = parseJson(response)
  if not data then
    return "Account discovery failed: Invalid response"
  end

  -- Support both response formats
  local accountsData = data.accountsresponse or data.otherAccounts
  if not accountsData then
    return "Account discovery failed: No accounts found in response"
  end

  return parseAccounts(accountsData)
end

function parseAccounts(accountsResponse)
  local accounts = {}

  for _, acc in ipairs(accountsResponse) do
    local accountNumber = extractAccountNumber(acc.accountNumber)
    local displayNumber = acc.displayAccountNumber or (accountNumber ~= "unknown" and "*" .. accountNumber:sub(-4) or "*XXXX")

    table.insert(accounts, {
      name = acc.nickname or acc.description or "Presidential Account",
      accountNumber = acc.id,
      bankCode = CONSTANTS.bankCode,
      currency = "USD",
      type = mapAccountType(acc.accountType or acc.category),
      _displayNumber = displayNumber,
      _actualNumber = accountNumber,
      _balance = acc.balance or acc.availableBalance or 0
    })
  end

  return accounts
end

function extractAccountNumber(accountNumber)
  if type(accountNumber) == "table" then
    return accountNumber.hostValue or accountNumber.displayValue or "unknown"
  elseif type(accountNumber) == "string" then
    return accountNumber
  end
  return "unknown"
end

function mapAccountType(accountType)
  if not accountType then
    return AccountTypeGiro
  end

  local typeMap = {
    checking = AccountTypeGiro,
    savings = AccountTypeSavings,
    credit = AccountTypeCreditCard,
    card = AccountTypeCreditCard,
    loan = AccountTypeLoan,
    mortgage = AccountTypeLoan,
    investment = AccountTypeSecurities,
    brokerage = AccountTypeSecurities
  }

  local mapped = typeMap[accountType:lower():match("^(%a+)")]
  return mapped or AccountTypeGiro
end

function RefreshAccount(account, since)
  if not account then
    return { balance = 0, transactions = {} }
  end

  if not hasValidSession() then
    return { balance = 0, transactions = {} }
  end

  local accountId = resolveAccountId(account)
  if not accountId then
    return { balance = 0, transactions = {} }
  end

  local startDate, endDate = calculateDateRange(since)
  local url = buildTransactionsUrl(accountId, startDate, endDate)

  local response = connection:request("GET", url, nil, nil, buildRequestHeaders())
  updateCookies()

  if not response then
    return { balance = 0, transactions = {} }
  end

  local data = parseJson(response)
  if not data or not data.transactionsresponse then
    return { balance = 0, transactions = {} }
  end

  return parseTransactions(data.transactionsresponse)
end

function resolveAccountId(account)
  local accountId = account._internalId or account.accountNumber

  if isValidAccountId(accountId) then
    return accountId
  end

  -- Try to discover accounts dynamically
  local discovered = ListAccounts({})
  if type(discovered) == "table" and #discovered > 0 then
    return discovered[1].accountNumber
  end

  return nil
end

function isValidAccountId(accountId)
  return accountId and accountId ~= "" and accountId ~= "0" and accountId ~= "PLACEHOLDER" and accountId ~= "0000000000"
end

function calculateDateRange(since)
  local endDate = os.date("%Y-%m-%d %H:%M:%S", os.time())
  local now = os.time()
  local oneYearAgo = os.time({year = os.date("%Y", now) - 1, month = os.date("%m", now), day = os.date("%d", now)})

  local startDate
  if since and since > oneYearAgo then
    startDate = os.date("%Y-%m-%d %H:%M:%S", since)
  else
    local tenYearsAgo = os.time({year = os.date("%Y", now) - 10, month = 1, day = 1})
    startDate = os.date("%Y-%m-%d %H:%M:%S", tenYearsAgo)
  end

  return startDate, endDate
end

function buildTransactionsUrl(accountId, startDate, endDate)
  local url = CONSTANTS.acctsApi .. "/history/transactions?accountId=" .. MM.urlencode(accountId)
    .. "&dateRangeEnd=" .. MM.urlencode(endDate)
    .. "&dateRangeStart=" .. MM.urlencode(startDate)
    .. "&locationId=&locationName=&pageId=history"
  -- Add rftoken as URL parameter (like browser does)
  if session.rftoken then
    url = url .. "&rftoken=" .. MM.urlencode(session.rftoken)
  end
  return url
end

function parseTransactions(transactionsResponse)
  local balance = 0
  local transactions = {}

  for _, tx in ipairs(transactionsResponse) do
    local txAmount = tonumber(tx.amount) or 0
    local isCredit = tx.creditTransaction or false
    local txType = tx.transactionType or ""

    if txType:lower() == "withdrawal" or txType:lower() == "debit" or isCredit == false then
      txAmount = -math.abs(txAmount)
    else
      txAmount = math.abs(txAmount)
    end

    if tx.ledgerBalance then
      balance = tonumber(tx.ledgerBalance) or balance
    end

    local name, purpose = parseTransactionDescription(tx.generatedDescription or "")

    table.insert(transactions, {
      bookingDate = parseDate(tx.transactionDate),
      valueDate = parseDate(tx.transactionDate),
      amount = txAmount,
      purpose = purpose,
      name = name
    })
  end

  return { balance = balance, transactions = transactions }
end

function parseTransactionDescription(description)
  if not description or description == "" then
    return "", ""
  end

  -- Pattern: "Type ENTITY / NAME - DETAILS"
  local prefix, entity, detail = description:match("^([^/]+)%s+([^/]+)%s*/%s*([^%-]+)%-%s*(.+)$")
  if prefix and entity and detail then
    local name = normalizeWhitespace(entity .. " " .. detail)
    local purpose = normalizeWhitespace(prefix .. " - " .. detail)
    return name, purpose
  end

  -- Pattern: "Type / NAME - DETAILS"
  local prefix2, name2, detail2 = description:match("^([^/]+)%s*/%s*([^%-]+)%-%s*(.+)$")
  if prefix2 and name2 and detail2 then
    return normalizeWhitespace(name2), normalizeWhitespace(prefix2 .. " - " .. detail2)
  end

  -- Pattern: "Before / After" (no dash)
  local beforeSlash, afterSlash = description:match("^(.-)%s*/%s*(.+)$")
  if beforeSlash and afterSlash then
    local slashName, slashDetail = afterSlash:match("^(.-)%s*%-%s*(.+)$")
    if slashName and slashDetail then
      return normalizeWhitespace(slashName), normalizeWhitespace(beforeSlash .. " - " .. slashDetail)
    end
    return normalizeWhitespace(afterSlash), normalizeWhitespace(beforeSlash)
  end

  -- Simple description, no slash/dash
  return "", description
end

function normalizeWhitespace(str)
  return str:gsub("^%s*(.-)%s*$", "%1"):gsub("%s+", " ")
end

function loginWithImportedCookies(cookieString)
  -- Remove "COOKIE:" prefix if present
  cookieString = cookieString:gsub("^COOKIE:", "")

  local formattedCookies = cookieString:gsub("^%s*(.-)%s*$", "%1")

  if not formattedCookies:match("=") then
    return "Invalid cookie format. Use: name=value;name2=value2"
  end

  -- Check for critical cookies and log presence
  local hasSessionToken = formattedCookies:match("SESSION_TOKEN") ~= nil
  local hasRftoken = formattedCookies:match("rftoken=") ~= nil
  if not hasSessionToken or not hasRftoken then
    return "Cookie import failed: Required cookies (SESSION_TOKEN, rftoken) not found."
  end

  session.rftoken = formattedCookies:match("rftoken=([^;]+)")
  session.cookies = formattedCookies
  session.cookieImportMode = true

  -- Test endpoint - use auth API like browser does
  local testResponse = connection:request("GET",
    CONSTANTS.authApi .. "/user/authtoken",
    nil, nil, buildRequestHeaders())

  if testResponse and testResponse:match("{") then
    -- Now test history endpoint WITH rftoken as URL parameter (like browser does)
    -- Note: The web app uses /history, not /accounts for account listing
    local acctUrl = CONSTANTS.acctsApi .. "/history?allowAccountsCall=true&getExportAccountNums=true&getxuseraccts&locationId&pageId=history&transfers_display_xuser_accounts"
    if session.rftoken then
      acctUrl = acctUrl .. "&rftoken=" .. session.rftoken
    end
    local acctResponse = connection:request("GET", acctUrl, nil, nil, buildRequestHeaders())
    if acctResponse and (acctResponse:match("accountsresponse") or acctResponse:match("otherAccounts")) then
      return nil
    end
  end

  -- Cookie import failed
  return "Cookie import failed (403 Forbidden). The bank rejected the cookies. This is likely due to: (1) IP address binding - cookies only work from same IP as browser, (2) Cloudflare security checks, or (3) Session already expired."
end

function handleCookieImportStep(credentials)
  local cookieString = credentials[1]

  if not cookieString or cookieString == "" then
    session.waitingForCookieImport = nil
    return "Cookie import cancelled. Please try again with valid cookies from your browser."
  end

  -- Remove "COOKIE:" prefix if present (from Python script output)
  cookieString = cookieString:gsub("^COOKIE:", "")

  -- Clean up the cookie string
  local formattedCookies = cookieString:gsub("^%s*(.-)%s*$", "%1")

  if not formattedCookies:match("rftoken=") then
    -- Keep the challenge open for retry
    return {
      title = "Cookie Import Required",
      challenge = "Cookie string must include rftoken. Please copy the COMPLETE Cookie header from your browser (including SESSION_TOKEN and rftoken).",
      label = "Cookie string"
    }
  end

  -- Extract rftoken and store cookies
  session.rftoken = formattedCookies:match("rftoken=([^;]+)")
  session.cookies = formattedCookies
  session.cookieImportMode = true
  session.waitingForCookieImport = nil

  -- Test if the imported cookies work - add rftoken as URL parameter
  local testUrl = CONSTANTS.acctsApi .. "/history?allowAccountsCall=true&getExportAccountNums=true&getxuseraccts&locationId&pageId=history&transfers_display_xuser_accounts"
  if session.rftoken then
    testUrl = testUrl .. "&rftoken=" .. MM.urlencode(session.rftoken)
  end
  local testResponse = connection:request("GET", testUrl, nil, nil, buildRequestHeaders())

  if testResponse and (testResponse:match("accountsresponse") or testResponse:match("otherAccounts")) then
    MM.printStatus("Cookie import successful - API access verified")
    return nil
  end

  -- Classify failure from the response body (Connection:request returns
  -- (content, charset, mimeType, filename, headers); MoneyMoney does NOT
  -- surface the HTTP status code, so we have to inspect the body).
  local body = testResponse and testResponse:lower() or ""
  if body:find("forbidden") or body:find("unauthorized") or body:find("\"status\"%s*:%s*40") then
    return "Cookie import failed: Invalid or expired session. Please login to Presidential Bank in your browser again, copy fresh cookies from DevTools → Network (including SESSION_TOKEN and rftoken), and retry."
  end
  if body:find("internal server error") or body:find("\"status\"%s*:%s*500") then
    session.waitingForCookieImport = true
    return {
      title = "Cookie Import - Server Error",
      challenge = "The server returned an internal error. This may be temporary.\n\nPlease try again with the same cookies, or get fresh cookies from your browser:",
      label = "Cookie string"
    }
  end

  return "Cookie import failed. The session may be expired or the cookies are incomplete. Please login to Presidential Bank in your browser, copy fresh cookies from DevTools → Network (including SESSION_TOKEN and rftoken), and retry."
end

function hasValidSession()
  return session.cookies and session.cookies ~= "" and session.cookies:match("SESSION_TOKEN")
end

function buildApiHeaders(cookies)
  return {
    ["Accept"] = "application/json, text/plain, */*",
    ["Content-Type"] = "application/json",
    ["Origin"] = CONSTANTS.baseUrl,
    ["Referer"] = CONSTANTS.baseUrl .. "/dbank/live/app/mfa",
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Cookie"] = cookies
  }
end

function buildRequestHeaders()
  -- Headers matching browser API request exactly (from HAR analysis)
  local headers = {
    ["Accept"] = "*/*",
    ["Accept-Language"] = "de-DE,de;q=0.9",
    ["Referer"] = CONSTANTS.baseUrl .. "/dbank/live/app/home/olb/history?accountId=D0",
    ["Sec-Fetch-Dest"] = "empty",
    ["Sec-Fetch-Mode"] = "cors",
    ["Sec-Fetch-Site"] = "same-origin",
    ["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15",
    ["Cookie"] = session.cookies or ""
  }

  return headers
end

function extractCookieValue(cookies, name)
  if not cookies then return nil end
  return cookies:match(name .. "=([^;]+)")
end

function updateCookies()
  if session.cookieImportMode then
    return
  end

  local newCookies = connection:getCookies()
  -- Only update if we actually got cookies with SESSION in them
  -- (getCookies() cannot see HttpOnly cookies, so don't overwrite them)
  if newCookies and newCookies:match("SESSION") then
    session.cookies = newCookies
  end
end

function parseJson(str)
  if not str then
    return nil
  end

  local success, result = pcall(function()
    return JSON(str):dictionary()
  end)

  if success then
    return result
  end
  return nil
end

function parseDate(dateStr)
  if not dateStr or dateStr == "" then
    return nil
  end

  -- ISO format: YYYY-MM-DD
  local year, month, day = dateStr:match("(%d%d%d%d)-(%d%d)-(%d%d)")
  if year and month and day then
    return os.time({year = tonumber(year), month = tonumber(month), day = tonumber(day)})
  end

  -- US format: MM/DD/YYYY
  month, day, year = dateStr:match("(%d%d?)/(%d%d?)/(%d%d%d%d)")
  if month and day and year then
    return os.time({year = tonumber(year), month = tonumber(month), day = tonumber(day)})
  end

  return nil
end

function extractCsrfTokenFromCookies(cookies)
  if not cookies then
    return nil
  end
  return cookies:match("CSRFToken=([^;]+)")
end

function EndSession()
  if session.cookies and session.cookies ~= "" then
    pcall(function()
      connection:request("GET", CONSTANTS.baseUrl .. "/dbank/live/app/logout?reason=userlogout", nil, nil, {})
    end)
  end

  session = {}
  MM.printStatus("Logged out")
end
