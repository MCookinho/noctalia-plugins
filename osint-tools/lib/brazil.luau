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
    sum = sum + tonumber(base:sub(i, i)) * (#base + 2 - i)
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
  if string.rep(digits:sub(1, 1), 11) == digits then
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

local DDD_CITY = {
  ["11"] = "São Paulo", ["12"] = "São José dos Campos", ["13"] = "Santos",
  ["14"] = "Bauru", ["15"] = "Sorocaba", ["16"] = "Ribeirão Preto",
  ["17"] = "São José do Rio Preto", ["18"] = "Presidente Prudente", ["19"] = "Campinas",
  ["21"] = "Rio de Janeiro", ["22"] = "Campos dos Goytacazes",
  ["27"] = "Vitória", ["31"] = "Belo Horizonte", ["32"] = "Juiz de Fora",
  ["33"] = "Ipatinga", ["34"] = "Uberlândia", ["37"] = "Divinópolis", ["38"] = "Uberaba",
  ["41"] = "Curitiba", ["42"] = "Ponta Grossa", ["43"] = "Londrina",
  ["44"] = "Maringá", ["45"] = "Cascavel", ["46"] = "Francisco Beltrão",
  ["47"] = "Joinville", ["48"] = "Florianópolis", ["49"] = "Chapecó",
  ["51"] = "Porto Alegre", ["53"] = "Pelotas", ["54"] = "Passo Fundo", ["55"] = "Santa Maria",
  ["61"] = "Brasília", ["62"] = "Goiânia", ["63"] = "Palmas", ["64"] = "Rio Verde",
  ["65"] = "Cuiabá", ["66"] = "Rondonópolis", ["67"] = "Campo Grande",
  ["68"] = "Rio Branco", ["69"] = "Porto Velho",
  ["71"] = "Salvador", ["73"] = "Ilhéus", ["74"] = "Vitória da Conquista",
  ["75"] = "Feira de Santana", ["77"] = "Barreiras", ["79"] = "Aracaju",
  ["81"] = "Recife", ["82"] = "Maceió", ["83"] = "João Pessoa", ["84"] = "Natal",
  ["85"] = "Fortaleza", ["86"] = "Teresina", ["87"] = "Petrolina",
  ["88"] = "Juazeiro do Norte", ["89"] = "Picos",
  ["91"] = "Belém", ["92"] = "Manaus", ["95"] = "Boa Vista", ["96"] = "Macapá",
  ["98"] = "São Luís", ["99"] = "Imperatriz",
}

local UF_REGION = {
  AC = "norte", AL = "nordeste", AP = "norte", AM = "norte", BA = "nordeste",
  CE = "nordeste", DF = "centro-oeste", ES = "sudeste", GO = "centro-oeste",
  MA = "nordeste", MT = "centro-oeste", MS = "centro-oeste", MG = "sudeste",
  PA = "norte", PB = "nordeste", PR = "sul", PE = "nordeste", PI = "nordeste",
  RJ = "sudeste", RN = "nordeste", RS = "sul", RO = "norte", RR = "norte",
  SC = "sul", SP = "sudeste", SE = "nordeste", TO = "norte",
}

function M.dddCity(ddd)
  return DDD_CITY[ddd]
end

function M.ufRegion(uf)
  return UF_REGION[uf]
end

local function phoneClass(digits)
  if digits:sub(1, 3) == "080" then
    return "toll_free"
  end
  if digits:sub(1, 4) == "0300" or digits:sub(1, 4) == "0500" or digits:sub(1, 4) == "0900" then
    return "commercial"
  end
  if #digits >= 10 then
    local p = digits:sub(1, 4)
    if p == "4003" or p == "4004" or p == "3003" or p == "3004" or p == "4090" then
      return "commercial"
    end
  end
  if #digits >= 2 and digits:sub(1, 2) == "19" then
    return "special"
  end
  return nil
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
        class = isMobile and "mobile" or "landline",
        national = national,
        e164 = "+55" .. ddd .. number,
        uf = M.dddUf(ddd),
        city = M.dddCity(ddd),
        region = M.ufRegion(M.dddUf(ddd)),
      }
    end
  end

  if #digits >= 7 and #digits <= 15 then
    return {
      ok = true,
      country = "?",
      isMobile = nil,
      class = phoneClass(digits),
      national = digits,
      e164 = "+" .. digits,
      uf = nil,
      generic = true,
    }
  end

  return nil
end

return M