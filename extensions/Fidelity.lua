--
-- MoneyMoney Web Banking extension for Fidelity Investments
-- https://www.fidelity.com
--
-- MIT License
--
-- Based on HAR analysis: digital.fidelity.com.har
-- Uses GraphQL API for positions
--
-- COOKIE IMPORT MODE:
--   1. Login to Fidelity in your browser
--   2. Open DevTools → Application/Storage → Cookies
--   3. Copy all cookies for digital.fidelity.com
--   4. In MoneyMoney, username = your username
--   5. Password = COOKIE: followed by cookies (semicolon-separated)
--      Example: COOKIE:_abck=xxx;bm_sz=yyy;ATC=zzz;ET=aaa
--
-- CLEANUP: Removed debug statements, consolidated headers
--

WebBanking {
  version = "1.0.0",
  url = "https://www.fidelity.com",
  services = {"Fidelity"},
  description = "Fidelity Investments - GraphQL API with Cookie Import support"
}

local CONSTANTS = {
  loginApi = "https://ecaap.fidelity.com/user/factor/password/authentication",
  sessionApi = "https://ecaap.fidelity.com/user/session/login",
  graphqlApi = "https://digital.fidelity.com/ftgw/digital/portfolio/api/graphql",
  activityApi = "https://digital.fidelity.com/ftgw/digital/webactivity/api/graphql",
  documentsApi = "https://digital.fidelity.com/ftgw/digital/documents/api/graphql",
  portfolioSummary = "https://digital.fidelity.com/ftgw/digital/portfolio/summary",
  activityPage = "https://digital.fidelity.com/ftgw/digital/portfolio/activity",
  documentsPage = "https://digital.fidelity.com/ftgw/digital/portfolio/documents",
  logoutUrl = "https://www.fidelity.com/logout"
}

local connection
local session = { cookies = "" }

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and (bankCode == "Fidelity" or bankCode == "Fidelity Investments")
end

function InitializeSession(protocol, bankCode, username, username2, password, username3)
  connection = Connection()
  connection.language = "en-US"
  connection.useragent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"

  -- Cookie import mode
  if password and password:match("^COOKIE:") then
    return loginWithImportedCookies(password:sub(8))
  end

  MM.printStatus("Logging in to Fidelity...")

  -- Load login page
  local _, _ = connection:request("GET", "https://digital.fidelity.com/prgw/digital/signin/retail", nil, nil, {
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Accept-Language"] = "en-US,en;q=0.9"
  })
  session.cookies = connection:getCookies() or ""

  -- Login with credentials
  local loginBody = JSON():set({
    username = username,
    password = password,
    deviceInfo = { deviceType = "browser", browser = "Safari", os = "MacOS" }
  }):json()

  local loginHeaders = {
    ["Accept"] = "*/*",
    ["Content-Type"] = "application/json",
    ["Cookie"] = session.cookies,
    ["Origin"] = "https://digital.fidelity.com",
    ["Referer"] = "https://digital.fidelity.com/",
    ["AppId"] = "RETAIL-CC-LOGIN-SDK",
    ["Token-Location"] = "HEADER",
    ["Accept-Token-Type"] = "ET",
    ["Accept-Token-Location"] = "HEADER"
  }

  local loginResponse, _, mimeType = connection:request("POST", CONSTANTS.loginApi, loginBody, "application/json", loginHeaders)
  session.cookies = connection:getCookies() or session.cookies

  if not loginResponse then
    return "Login failed: No response from server"
  end

  -- Parse response
  if mimeType and mimeType:find("json") then
    local success, jsonData = pcall(function() return JSON(loginResponse):dictionary() end)
    if success and jsonData then
      if jsonData.sysMsgs and jsonData.sysMsgs.sysMsg then
        local sysMsg = jsonData.sysMsgs.sysMsg[1] or jsonData.sysMsgs.sysMsg
        if sysMsg then
          return "Login failed: " .. (sysMsg.message or sysMsg.detail or "Unknown error")
        end
      end
      if jsonData.error or jsonData.errorCode then
        return LoginFailed
      end
      if jsonData.token or jsonData.accessToken then
        return nil
      end
    end
  end

  -- Check for session cookies
  if session.cookies:match("ATC") or session.cookies:match("ET") then
    MM.printStatus("Login successful")
    return nil
  end

  return "Login failed. Try Cookie Import mode with 'COOKIE:' prefix."
end

function loginWithImportedCookies(cookieString)
  MM.printStatus("Using imported cookies...")

  -- Convert comma-separated to semicolon-separated if needed
  local formattedCookies = cookieString:gsub("^%s*(.-)%s*$", "%1")
  if formattedCookies:match(",") and not formattedCookies:match(";") then
    formattedCookies = formattedCookies:gsub("%s*,%s*", "; ")
  end

  if not formattedCookies:match("=") then
    return "Invalid cookie format. Use: name=value;name2=value2"
  end

  session.cookies = formattedCookies

  -- Test session
  local testHeaders = {
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Accept-Language"] = "en-US,en;q=0.9",
    ["Cookie"] = session.cookies
  }

  local testResponse, _ = connection:request("GET", CONSTANTS.portfolioSummary, nil, nil, testHeaders)

  if testResponse and (testResponse:match("portfolio") or testResponse:match("Portfolio Summary")) then
    MM.printStatus("Cookie import successful")
    return nil
  end

  return "Cookie import failed. Please copy fresh cookies from browser."
end

function ListAccounts(knownAccounts)
  MM.printStatus("Fetching Fidelity accounts...")

  local accountQuery = {
    operationName = "GetContext",
    variables = {},
    query = [[query GetContext {
      getContext {
        person {
          assets {
            acctNum
            acctType
            acctSubType
            acctSubTypeDesc
            gainLossBalanceDetail {
              totalMarketVal
              __typename
            }
            __typename
          }
          __typename
        }
        __typename
      }
    }]]
  }

  local headers = {
    ["Accept"] = "*/*",
    ["Content-Type"] = "application/json",
    ["Cookie"] = session.cookies,
    ["Origin"] = "https://digital.fidelity.com",
    ["Referer"] = CONSTANTS.portfolioSummary,
    ["apollographql-client-version"] = "0.0.0"
  }

  local response, _ = connection:request("POST", CONSTANTS.graphqlApi .. "?ref_at=portsum",
    JSON():set(accountQuery):json(), "application/json", headers)
  session.cookies = connection:getCookies() or session.cookies

  if not response then
    return "Failed to fetch accounts"
  end

  local accounts = {}
  local success, data = pcall(function() return JSON(response):dictionary() end)

  if success and data and data.data and data.data.getContext and data.data.getContext.person then
    local person = data.data.getContext.person
    if person.assets then
      for _, acc in ipairs(person.assets) do
        local acctType = acc.acctSubTypeDesc or acc.acctType or "Account"
        table.insert(accounts, {
          name = "Fidelity " .. acctType,
          accountNumber = acc.acctNum,
          portfolio = true,
          currency = "USD",
          type = AccountTypePortfolio,
          bankCode = "Fidelity"
        })
      end
    end
  end

  if #accounts == 0 then
    return "No accounts found"
  end

  return accounts
end

function RefreshAccount(account, since)
  if not account or not account.accountNumber then
    return { balance = 0, securities = {} }
  end

  MM.printStatus("Refreshing account: " .. account.name)

  -- Get positions via GraphQL
  local positionsQuery = {
    operationName = "GetPositions",
    variables = {
      acctList = { { acctNum = account.accountNumber, acctType = "Brokerage", acctSubType = "Mutual Fund", preferenceDetail = false } },
      customerId = ""
    },
    query = [[query GetPositions($acctList: [PositionAccountInput], $customerId: String) {
      getPosition(acctList: $acctList, customerId: $customerId) {
        position {
          acctDetails {
            acctDetail {
              acctNum
              positionDetails {
                positionDetail {
                  symbol
                  cusip
                  securityDescription
                  quantity
                  marketValDetail {
                    marketVal
                    totalGainLoss
                    __typename
                  }
                  __typename
                }
                __typename
              }
              __typename
            }
            __typename
          }
          __typename
        }
        topBottomPositions {
          symbol
          lastPrice
          __typename
        }
        __typename
      }
    }]]
  }

  local headers = {
    ["Accept"] = "*/*",
    ["Content-Type"] = "application/json",
    ["Cookie"] = session.cookies,
    ["Origin"] = "https://digital.fidelity.com",
    ["Referer"] = CONSTANTS.portfolioSummary,
    ["apollographql-client-version"] = "0.0.0"
  }

  local response, _ = connection:request("POST", CONSTANTS.graphqlApi .. "?ref_at=portsum",
    JSON():set(positionsQuery):json(), "application/json", headers)
  session.cookies = connection:getCookies() or session.cookies

  if not response then
    return { balance = 0, securities = {} }
  end

  local success, data = pcall(function() return JSON(response):dictionary() end)
  if not success or not data then
    return { balance = 0, securities = {} }
  end

  local securities = {}
  local totalBalance = 0
  local priceLookup = {}

  -- Build price lookup from topBottomPositions
  if data.data and data.data.getPosition and data.data.getPosition.topBottomPositions then
    for _, pos in ipairs(data.data.getPosition.topBottomPositions) do
      if pos.symbol and pos.lastPrice then
        priceLookup[pos.symbol] = tonumber(pos.lastPrice) or 0
      end
    end
  end

  -- Extract positions
  if data.data and data.data.getPosition and data.data.getPosition.position then
    local position = data.data.getPosition.position
    if position.acctDetails and position.acctDetails.acctDetail then
      for _, acct in ipairs(position.acctDetails.acctDetail) do
        if acct.positionDetails and acct.positionDetails.positionDetail then
          for _, pos in ipairs(acct.positionDetails.positionDetail) do
            local symbol = pos.symbol or ""
            local quantity = tonumber(pos.quantity) or 0
            local marketVal = 0
            local totalGainLoss = 0

            if pos.marketValDetail then
              marketVal = tonumber(pos.marketValDetail.marketVal) or 0
              totalGainLoss = tonumber(pos.marketValDetail.totalGainLoss) or 0
            end

            local currentPrice = priceLookup[symbol] or 0
            if currentPrice == 0 and quantity > 0 then
              currentPrice = marketVal / quantity
            end

            local purchasePrice = 0
            if quantity > 0 and marketVal > 0 then
              local costBasis = marketVal - totalGainLoss
              purchasePrice = costBasis / quantity
            end

            table.insert(securities, {
              name = pos.securityDescription or symbol or "Unknown",
              isin = pos.cusip or "",
              securityNumber = symbol,
              quantity = quantity,
              price = currentPrice,
              purchasePrice = purchasePrice,
              amount = marketVal,
              currencyOfPrice = "USD",
              currencyOfOriginalAmount = "USD"
            })

            totalBalance = totalBalance + marketVal
          end
        end
      end
    end
  end

  return { balance = totalBalance, securities = securities }
end

function EndSession()
  if session.cookies and session.cookies ~= "" then
    pcall(function()
      connection:request("GET", CONSTANTS.logoutUrl, nil, nil, { ["Cookie"] = session.cookies })
    end)
  end
  MM.printStatus("Logged out")
end

-- SIGNATURE: MC4CFQCbwcy5iiv/AJGS3E85IYCIXkbltgIVAIHAMbH4w6H5GLVc1KNxCJkhTYyG
