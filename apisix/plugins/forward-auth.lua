--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local ipairs   = ipairs
local core     = require("apisix.core")
local http     = require("resty.http")
local pairs    = pairs
local type     = type
local tostring = tostring

local schema = {
    type = "object",
    properties = {
        uri = {type = "string"},
        allow_degradation = {type = "boolean", default = false},
        status_on_error = {type = "integer", minimum = 200, maximum = 599, default = 403},
        ssl_verify = {
            type = "boolean",
            default = true,
        },
        request_method = {
            type = "string",
            default = "GET",
            enum = {"GET", "POST"},
            description = "the method for client to request the authorization service"
        },
        request_headers = {
            type = "array",
            default = {},
            items = {type = "string"},
            description = "client request header that will be sent to the authorization service"
        },
        extra_headers = {
            type = "object",
            minProperties = 1,
            patternProperties = {
                ["^[^:]+$"] = {
                    type = "string",
                    description = "header value as a string; may contain variables"
                                  .. "like $remote_addr, $request_uri"
                }
            },
            description = "extra headers sent to the authorization service; "
                        .. "values must be strings and can include variables"
                        .. "like $remote_addr, $request_uri."
        },
        upstream_headers = {
            type = "array",
            default = {},
            items = {type = "string"},
            description = "authorization response header that will be sent to the upstream"
        },
        client_headers = {
            type = "array",
            default = {},
            items = {type = "string"},
            description = "authorization response header that will be sent to"
                           .. "the client when authorizing failed"
        },
        timeout = {
            type = "integer",
            minimum = 1,
            maximum = 60000,
            default = 3000,
            description = "timeout in milliseconds",
        },
        keepalive = {type = "boolean", default = true},
        keepalive_timeout = {type = "integer", minimum = 1000, default = 60000},
        keepalive_pool = {type = "integer", minimum = 1, default = 5},
    },
    required = {"uri"}
}


local _M = {
    version = 0.1,
    priority = 2002,
    name = "forward-auth",
    schema = schema,
}


function _M.check_schema(conf)
    local check = {"uri"}
    core.utils.check_https(check, conf, _M.name)
    core.utils.check_tls_bool({"ssl_verify"}, conf, _M.name)

    return core.schema.check(schema, conf)
end


function _M.access(conf, ctx)
    local auth_headers = {
        ["X-Forwarded-Proto"] = core.request.get_scheme(ctx),
        ["X-Forwarded-Method"] = core.request.get_method(),
        ["X-Forwarded-Host"] = core.request.get_host(ctx),
        ["X-Forwarded-Uri"] = ctx.var.request_uri,
        ["X-Forwarded-For"] = core.request.get_remote_client_ip(ctx),
    }

    if conf.request_method == "POST" then
        auth_headers["Content-Length"] = core.request.header(ctx, "content-length")
        auth_headers["Expect"] = core.request.header(ctx, "expect")
        auth_headers["Transfer-Encoding"] = core.request.header(ctx, "transfer-encoding")
        auth_headers["Content-Encoding"] = core.request.header(ctx, "content-encoding")
    end

    if conf.extra_headers then
        for header, value in pairs(conf.extra_headers) do
            if type(value) == "number" then
                value = tostring(value)
            end
            local resolve_value, err = core.utils.resolve_var(value, ctx.var)
            if not err then
                auth_headers[header] = resolve_value
            end
            if err then
                core.log.error("failed to resolve variable in extra header '",
                                header, "': ",value,": ",err)
            end
        end
    end

    -- append headers that need to be get from the client request header
    if #conf.request_headers > 0 then
        for _, header in ipairs(conf.request_headers) do
            if not auth_headers[header] then
                auth_headers[header] = core.request.header(ctx, header)
            end
        end
    end

    local params = {
        headers = auth_headers,
        keepalive = conf.keepalive,
        ssl_verify = conf.ssl_verify,
        method = conf.request_method
    }

    if params.method == "POST" then
        params.body = core.request.get_body()
    end

    if conf.keepalive then
        params.keepalive_timeout = conf.keepalive_timeout
        params.keepalive_pool = conf.keepalive_pool
    end

    local httpc = http.new()
    httpc:set_timeout(conf.timeout)

    local res, err = httpc:request_uri(conf.uri, params)
    if not res and conf.allow_degradation then
        return
    elseif not res then
        core.log.warn("failed to process forward auth, err: ", err)
        return conf.status_on_error
    end

    if res.status >= 300 then
        local client_headers = {}

        if #conf.client_headers > 0 then
            for _, header in ipairs(conf.client_headers) do
                client_headers[header] = res.headers[header]
            end
        end

        core.response.set_header(client_headers)
        return res.status, res.body
    end

    -- append headers that need to be get from the auth response header
    for _, header in ipairs(conf.upstream_headers) do
        local header_value = res.headers[header]
        if header_value then
            core.request.set_header(ctx, header, header_value)
        end
    end
end


return _M
