--!nonstrict
-- Brazilian document / phone helpers (CPF validation, DDD map, phone parsing).
local M = {}

local DDD_UF = {
  ["11"] = "SP", ["12"] = "SP", ["13"] = "SP", ["14"] = "SP",
  ["15"] = "SP", ["16"] = "SP", ["17"] = "SP", ["18"] = "SP", ["19"] = "SP",
  ["21"] = "RJ", ["22"] = "RJ", ["24"] = "RJ",
  ["27"] = "ES", ["28"] = "ES",
  ["31"] = "MG", ["32"] = "MG", ["33"] = "MG", ["34"] = "MG",
  ["35"] = "MG", ["37"] = "MG", ["38"] = "MG",
  ["41"] = "PR", ["42"] = "PR", ["43"] = "PR", ["44"] = "PR",
  ["45"] = "PR", ["46"] = "PR",
  ["47"] = "SC", ["48"] = "SC", ["49"] = "SC",
  ["51"] = "RS", ["53"] = "RS", ["54"] = "RS", ["55"] = "RS",
  ["61"] = "DF", ["62"] = "GO", ["63"] = "TO", ["64"] = "TO",
  ["65"] = "MT", ["66"] = "MT", ["67"] = "MS", ["68"] = "AC", ["69"] = "RO",
  ["71"] = "BA", ["73"] = "BA", ["74"] = "BA", ["75"] = "BA",
  ["77"] = "BA", ["79"] = "SE",
  ["81"] = "PE", ["82"] = "AL", ["83"] = "PB", ["84"] = "RN",
  ["85"] = "CE", ["86"] = "PI", ["87"] = "PE", ["88"] = "CE", ["89"] = "PI",
  ["91"] = "PA", ["92"] = "PA", ["93"] = "PA", ["94"] = "PA",
  ["95"] = "RR", ["96"] = "AP", ["97"] = "AM", ["98"] = "MA", ["99"] = "MA",
}

function M.dddUf(ddd)
  return DDD_UF[ddd]
end

function M.onlyDigits(value)
  return tostring(value or ""):gsub("%D", "")
end

local function checkDigit(base)
  local sum = 0
  for i = 1, #base do
    sum = sum + tonumber(base:sub(i, i)) * (#base + 1 - i)
  end
  local rest = (sum * 10) % 11
  if rest == 10 then
    rest = 0
  end
  return rest
end

function M.cpfIsValid(digits)
  digits = M.onlyDigits(digits)
  if #digits ~= 11 then
    return false
  end
  if digits:match("^(%d)%1*$") then
    return false
  end
  local d1 = checkDigit(digits:sub(1, 9))
  if d1 ~= tonumber(digits:sub(10, 10)) then
    return false
  end
  local d2 = checkDigit(digits:sub(1, 10))
  return d2 == tonumber(digits:sub(11, 11))
end

local UFR_BY_DIGIT = {
  ["1"] = { "DF", "GO", "MS", "MT" },
  ["2"] = { "AC", "AM", "AP", "PA", "RO", "RR" },
  ["3"] = { "CE", "MA", "PI" },
  ["4"] = { "AL", "PB", "PE", "RN" },
  ["5"] = { "BA", "SE" },
  ["6"] = { "MG" },
  ["7"] = { "ES", "RJ" },
  ["8"] = { "SP" },
  ["9"] = { "PR", "SC" },
  ["0"] = { "RS" },
}

function M.cpfUfr(digits)
  local digit = digits:sub(9, 9)
  return UFR_BY_DIGIT[digit] or nil
end

function M.cpfFormat(digits)
  return string.format("%s.%s.%s-%s",
    digits:sub(1, 3), digits:sub(4, 6), digits:sub(7, 9), digits:sub(10, 11))
end

function M.phoneParse(raw)
  local digits = M.onlyDigits(raw)
  if #digits == 0 then
    return nil
  end

  if #digits == 13 and digits:sub(1, 2) == "55" then
    digits = digits:sub(3)
  end
  if #digits == 12 and digits:sub(1, 2) == "55" then
    digits = digits:sub(3)
  end

  if #digits >= 10 and #digits <= 11 then
    local ddd = digits:sub(1, 2)
    if M.dddUf(ddd) ~= nil then
      local number = digits:sub(3)
      local isMobile = #number == 9 and number:sub(1, 1) == "9"
      local national
      if #number == 9 then
        national = string.format("(%s) %s-%s", ddd, number:sub(1, 5), number:sub(6))
      else
        national = string.format("(%s) %s-%s", ddd, number:sub(1, 4), number:sub(5))
      end
      return {
        ok = true,
        country = "BR",
        ddd = ddd,
        number = number,
        isMobile = isMobile,
        national = national,
        e164 = "+55" .. ddd .. number,
        uf = M.dddUf(ddd),
      }
    end
  end

  if #digits >= 7 and #digits <= 15 then
    return {
      ok = true,
      country = "?",
      isMobile = nil,
      national = digits,
      e164 = "+" .. digits,
      uf = nil,
      generic = true,
    }
  end

  return nil
end

return M