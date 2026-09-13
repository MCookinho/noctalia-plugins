--!nonstrict
-- Pure-Luau MD5 (used to build the Gravatar hash for an e-mail address).
local M = {}

local S = {
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local K = {
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
  0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
  0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
  0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
  0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
  0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
  0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

local function byteList(str)
  assert(type(str) == "string", "md5 input must be a string")
  local out = {}
  for i = 1, #str do
    out[i] = str:byte(i)
  end
  return out
end

local function toLittleEndian(number, width)
  local out = {}
  local n = number
  for i = 1, width do
    out[i] = n % 256
    n = math.floor(n / 256)
  end
  return out
end

function M.md5(message)
  local bytes = byteList(message)
  local bitLen = #bytes * 8

  table.insert(bytes, 0x80)
  while (#bytes % 64) ~= 56 do
    table.insert(bytes, 0)
  end

  local lenLow = bitLen % 0x100000000
  local lenHigh = math.floor(bitLen / 0x100000000)
  for _, byte in ipairs(toLittleEndian(lenLow, 4)) do
    table.insert(bytes, byte)
  end
  for _, byte in ipairs(toLittleEndian(lenHigh, 4)) do
    table.insert(bytes, byte)
  end

  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476

  for chunk = 1, #bytes, 64 do
    local m = {}
    for j = 0, 15 do
      local base = chunk + j * 4
      m[j + 1] = (bytes[base]
        + bytes[base + 1] * 0x100
        + bytes[base + 2] * 0x10000
        + bytes[base + 3] * 0x1000000) % 0x100000000
    end

    local a, b, c, d = a0, b0, c0, d0

    for i = 1, 64 do
      local f, g
      if i <= 16 then
        f = bit32.bor(bit32.band(b, c), bit32.band(bit32.bnot(b), d))
        g = i
      elseif i <= 32 then
        f = bit32.bor(bit32.band(d, b), bit32.band(bit32.bnot(d), c))
        g = (5 * i - 4) % 16 + 1
      elseif i <= 48 then
        f = bit32.bxor(bit32.bxor(b, c), d)
        g = (3 * i + 2) % 16 + 1
      else
        f = bit32.bxor(c, bit32.bor(b, bit32.bnot(d)))
        g = (7 * i - 7) % 16 + 1
      end

      f = (f + a + K[i] + m[g]) % 0x100000000
      a = d
      d = c
      c = b
      b = (b + bit32.lrotate(f, S[i])) % 0x100000000
    end

    a0 = (a0 + a) % 0x100000000
    b0 = (b0 + b) % 0x100000000
    c0 = (c0 + c) % 0x100000000
    d0 = (d0 + d) % 0x100000000
  end

  local out = {}
  for _, word in ipairs({ a0, b0, c0, d0 }) do
    local little = toLittleEndian(word, 4)
    for i = 1, 4 do
      out[#out + 1] = string.format("%02x", little[i])
    end
  end
  return table.concat(out)
end

return M