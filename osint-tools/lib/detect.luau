--!nonstrict
-- Input classifier: decides whether a raw search string is a username,
-- e-mail, CPF or telephone number.
local M = {}

local brazil = require("./brazil.luau")

local EMAIL_PATTERN = "^[%w.+-]+@[%w-]+%.[%w.-]+$"

function M.isEmail(value)
  return tostring(value or ""):match(EMAIL_PATTERN) ~= nil
end

function M.isAllDigits(value)
  return tostring(value or ""):match("^%d+$") ~= nil
end

function M.hasPhoneChars(value)
  return tostring(value or ""):match("^[%d%s%+%-%(%)]+$") ~= nil
end

function M.detect(raw)
  local value = noctalia.string.trim(tostring(raw or ""))
  if value == "" then
    return nil
  end
  if M.isEmail(value) then
    return "email"
  end

  local digits = brazil.onlyDigits(value)

  if #digits == 11 and M.isAllDigits(value) then
    local ddd = digits:sub(1, 2)
    local number = digits:sub(3)
    if #number == 9 and number:sub(1, 1) == "9" and brazil.dddUf(ddd) ~= nil then
      return "phone"
    end
    return "cpf"
  end

  if #digits >= 10 and #digits <= 13 and M.hasPhoneChars(value) then
    return "phone"
  end

  return "username"
end

return M