-- Copyrigtht (C) 2013 Piotr Gaertig

local concat = table.concat
local match = string.match
local setmetatable = setmetatable
local tonumber = tonumber
local error = error
local print = print
local string = string
local math = math
local ngx = ngx
local type = type
local pairs = pairs
local crc32 = crc32


module(...)

local mt = { __index = _M }

_M.chunk_size = 4096
_M.socket_timeout = 30000

local function raw_body_by_chunk(self)
    if self.left == 0 then
       return nil
    end

    local current_chunk_size = self.left < self.chunk_size and self.left or self.chunk_size
    -- local current_chunk_size = math.min(self.left,self.chunk_size)
    self.left = self.left - current_chunk_size
    local chunk, err =  self.socket:receive(current_chunk_size)
    if err then
        return nil, err
    end

    return chunk
end

-- Checks request headers and creates upload context instance
function new(self, handlers)
    local ctx = {}
    local headers = ngx.req.get_headers()

    local content_length = tonumber(headers["content-length"])
    if not content_length then
      return nil, {412, "Content-Length missing"}
    end
    if content_length < 0 then
      return nil, {400, "Negative content length"}
    end

    local session_id = headers["session-id"] or headers["x-session-id"]
    if not session_id then
      -- TODO make optional in next version, back-end can assign session-id in url
      return nil, {412, "Session-id header missing"}
    else
      if session_id:match('%W') then
        return nil, {412, "Session-id is invalid (only alphanumeric value are accepted)"}
      end
    end

    local range_from, range_to, range_total
    local content_range = headers["content-range"] or headers["x-content-range"]
    if content_range then
      range_from, range_to, range_total = content_range:match("%s*bytes%s+(%d+)-(%d+)/(%d+)")
      if not (range_from and range_to and range_total) then
        return nil, {412, "Invalid Content-Range format"}
      end
      range_from = tonumber(range_from)
      range_to = tonumber(range_to)
      range_total = tonumber(range_total)
    else
      -- no resumable upload but keep range info for handlers
      range_from = 0
      range_to = math.max(content_length-1, 0)  -- CL=0 -> 0-0/0
      range_total = content_length
    end

    if range_from == 0 then
      ctx.first_chunk = true
    end

    ctx.range_from = range_from
    ctx.range_to = range_to
    ctx.range_total = range_total

    -- 0-0/0 means empty file 0-0/1 means one byte file, paradox but works
    if not(range_from == 0 and range_to == 0 and range_total == 0) then
        -- these should fail: 3-2/4 or 0-4/4
        if range_from > range_to or range_to > range_total-1 then
          return nil, {412, string.format("Range data invalid %d-%d/%d", range_to, range_from, range_total)}
        end

        --
        if content_length-1 ~= range_to - range_from then
          return nil, {412, "Range size does not match Content-Length"}
        end
    end

    if not handlers or #handlers == 0 then
      return nil, "Configuration error: no handlers defined"
    end

    ctx.get_name = function()
      local content_disposition = headers['Content-Disposition']
      if type(content_disposition) == "table" then
        -- Opera attaches second header on xhr.send - first one is ours
        content_disposition = content_disposition[1]
      end
      if content_disposition then
        -- http://greenbytes.de/tech/webdav/rfc5987.html
        local mname = string.match(
            content_disposition, "%s*%w+%s*;%s*%w+%s*=%s*\"?([^\"]+)")
          or string.match(
            content_disposition, "%s*%w+%s*;%s*%w+%*%s*=%s*UTF%-8''(.+)")  -- eventual UTF8 case
        if mname then
          return mname
        end
        ngx.log(ngx.WARN, "Couldn't extract file name from Content-Disposition:"..content_disposition)
      end
      return session_id --default
    end

    local last_checksum = headers['X-Last-Checksum'] -- checksum of last server-side chunk
    if last_checksum then
      if not crc32.validhex(last_checksum) then
        return nil, {400, "Bad X-Last-Checksum format: " .. last_checksum}
      end
      ctx.last_checksum = last_checksum
    end

    local checksum = headers['X-Checksum'] -- checksum from beginning of file up to current chunk
    if checksum then
      if not crc32.validhex(checksum) then
        return nil, {400, "Bad X-Checksum format: " .. checksum}
      end
      ctx.checksum = checksum
    end


    local socket

    -- prevent 'no body' error on empty request
    if content_length ~= 0 then
       local sk, err = ngx.req.socket()
       if not sk then
         return nil, {500, err, concat({"Socket error: ", err})}
       end
       sk:settimeout(socket_timeout)
       socket = sk
    end

    ctx.id = session_id

    return setmetatable({
        socket = socket,
        chunk_size = chunk_size,
        content_length = content_length,
        left = content_length,
        session_id = session_id,
        handlers = handlers,
        payload_context = ctx
    }, mt)
end

function process(self)
  for i, h in pairs(self.handlers) do
    local result = h.on_body_start and h:on_body_start(self.payload_context)
    if result then
      -- result from on_body_start means something important happened to stop upload
      return result
    end
  end
  if self.content_length ~= 0 then
      while true do
        local chunk, err = raw_body_by_chunk(self)
        if not chunk then
          if err then
            return err
          end
          break
        end
        for i, h in pairs(self.handlers) do
          local result = h.on_body and h:on_body(self.payload_context, chunk)
          if result then return result end
        end
      end
  end
  for i, h in pairs(self.handlers) do
    local result = h.on_body_end and h:on_body_end(self.payload_context)
    if result then return result end
  end
end

setmetatable(_M, {
  __newindex = function (_, n)
    error("attempt to write to undeclared variable "..n, 2)
  end,
  __index = function (_, n)
    error("attempt to read undeclared variable "..n, 2)
  end,
})

