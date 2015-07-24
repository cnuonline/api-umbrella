local api_store = require "api-umbrella.proxy.api_store"
local inspect = require "inspect"
local stringx = require "pl.stringx"
local types = require "pl.types"
local utils = require "api-umbrella.proxy.utils"

local apis_for_host = api_store.for_host
local append_array = utils.append_array
local get_packed = utils.get_packed
local gsub = string.gsub
local is_empty = types.is_empty
local set_uri = utils.set_uri
local startswith = stringx.startswith

local function apis_for_request_host()
  local apis = {}

  local all_apis = api_store.all_apis() or {}
  local fallback_apis = {}
  for _, api in ipairs(all_apis) do
    local matched_host = false
    if api["_frontend_host_wildcard_regex"] then
      local match, err = ngx.re.match(ngx.ctx.host_normalized, api["_frontend_host_wildcard_regex"], "jo")
      if match then
        matched_host = true
      end
    else
      if ngx.ctx.host_normalized == api["_frontend_host_normalized"] then
        matched_host = true
      end
    end

    if matched_host then
      table.insert(apis, api)
    elseif api["_frontend_host_normalized"] == config["_default_hostname"] then
      table.insert(fallback_apis, api)
    end
  end

  append_array(apis, fallback_apis)

  return apis
end

local function match_api(request_path)
  -- Find the API backends that match this host.
  local apis = apis_for_request_host()

  -- Search through each API backend for the first that matches the URL path
  -- prefix.
  for _, api in ipairs(apis) do
    if api["url_matches"] then
      for _, url_match in ipairs(api["url_matches"]) do
        if startswith(request_path, url_match["frontend_prefix"]) then
          return api, url_match
        end
      end
    end
  end
end

return function(user)
  local request_path = ngx.ctx.original_uri
  local api, url_match = match_api(request_path)

  if api and url_match then
    -- Rewrite the URL prefix path.
    new_path = gsub(request_path, url_match["_frontend_prefix_matcher"], url_match["backend_prefix"], 1)
    if new_path ~= request_path then
      set_uri(new_path)
    end

    local host = api["backend_host"] or ngx.ctx.host
    if api["_frontend_host_wildcard_regex"] then
      local match, err = ngx.re.match(ngx.ctx.host_normalized, api["_frontend_host_wildcard_regex"], "jo")
      local wildcard_portion = match[1]
      if wildcard_portion then
        host = ngx.re.sub(host, "^([*.])", wildcard_portion, "jo")
      end
    end

    -- Set the nginx headers that will determine which nginx upstream this
    -- request gets proxied to.
    ngx.req.set_header("X-Api-Umbrella-Backend-Scheme", api["backend_protocol"] or "http")
    ngx.req.set_header("X-Api-Umbrella-Backend-Host", host)
    ngx.req.set_header("X-Api-Umbrella-Backend-Id", api["_id"])

    return api
  else
    return nil, "not_found"
  end
end
