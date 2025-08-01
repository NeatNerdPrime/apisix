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

--- Etcd API.
--
-- @module core.etcd

local require           = require
local fetch_local_conf  = require("apisix.core.config_local").local_conf
local array_mt          = require("apisix.core.json").array_mt
local log               = require("apisix.core.log")
local try_read_attr     = require("apisix.core.table").try_read_attr
local v3_adapter        = require("apisix.admin.v3_adapter")
local etcd              = require("resty.etcd")
local clone_tab         = require("table.clone")
local health_check      = require("resty.etcd.health_check")
local pl_path           = require("pl.path")
local ipairs            = ipairs
local setmetatable      = setmetatable
local string            = string
local tonumber          = tonumber
local ngx_get_phase     = ngx.get_phase


local _M = {}


local NOT_ALLOW_WRITE_ETCD_WARN = 'Data plane role should not write to etcd. ' ..
    'This operation will be deprecated in future releases.'

local function is_data_plane()
    local local_conf, err = fetch_local_conf()
    if not local_conf then
        return nil, err
    end

    local role = try_read_attr(local_conf, "deployment", "role")
    if role == "data_plane" then
      return true
    end

    return false
end



local function disable_write_if_data_plane()
    local data_plane, err = is_data_plane()
    if err then
        log.error("failed to check data plane role: ", err)
        return true, err
    end

    if data_plane then
        -- current only warn, will be return false in future releases
        -- to block etcd write
        log.warn(NOT_ALLOW_WRITE_ETCD_WARN)
        return false
    end

    return false, nil
end


local function wrap_etcd_client(etcd_cli)
    -- note: methods txn can read and write, don't use txn to write when data plane role
    local methods_to_wrap = {
        "set",
        "setnx",
        "setx",
        "delete",
        "rmdir",
        "grant",
        "revoke",
        "keepalive"
    }

    local original_methods = {}
    for _, method in ipairs(methods_to_wrap) do
        if not etcd_cli[method] then
            log.error("method ", method, " not found in etcd client")
            return nil, "method " .. method .. " not found in etcd client"
        end

        original_methods[method] = etcd_cli[method]
    end

    for _, method in ipairs(methods_to_wrap) do
        etcd_cli[method] = function(self, ...)
            local disable, err = disable_write_if_data_plane()
            if disable then
                return nil, err
            end

            return original_methods[method](self, ...)
        end
    end

    return etcd_cli
end


local function _new(etcd_conf)
    local prefix = etcd_conf.prefix
    etcd_conf.http_host = etcd_conf.host
    etcd_conf.host = nil
    etcd_conf.prefix = nil
    etcd_conf.protocol = "v3"
    etcd_conf.api_prefix = "/v3"

    -- default to verify etcd cluster certificate
    etcd_conf.ssl_verify = true
    if etcd_conf.tls then
        if etcd_conf.tls.verify == false then
            etcd_conf.ssl_verify = false
        end

        if etcd_conf.tls.cert then
            etcd_conf.ssl_cert_path = etcd_conf.tls.cert
            etcd_conf.ssl_key_path = etcd_conf.tls.key
        end

        if etcd_conf.tls.sni then
            etcd_conf.sni = etcd_conf.tls.sni
        end
    end

    local etcd_cli, err = etcd.new(etcd_conf)
    if not etcd_cli then
        return nil, nil, err
    end

    etcd_cli = wrap_etcd_client(etcd_cli)

    return etcd_cli, prefix
end


---
-- Create an etcd client which will connect to etcd without being proxyed by conf server.
-- This method is used in init_worker phase when the conf server is not ready.
--
-- @function core.etcd.new_without_proxy
-- @treturn table|nil the etcd client, or nil if failed.
-- @treturn string|nil the configured prefix of etcd keys, or nil if failed.
-- @treturn nil|string the error message.
local function new_without_proxy()
    local local_conf, err = fetch_local_conf()
    if not local_conf then
        return nil, nil, err
    end

    local etcd_conf = clone_tab(local_conf.etcd)

    if local_conf.apisix.ssl and local_conf.apisix.ssl.ssl_trusted_certificate then
        etcd_conf.trusted_ca = local_conf.apisix.ssl.ssl_trusted_certificate
    end

    return _new(etcd_conf)
end
_M.new_without_proxy = new_without_proxy


local function new()
    local local_conf, err = fetch_local_conf()
    if not local_conf then
        return nil, nil, err
    end

    local etcd_conf = clone_tab(local_conf.etcd)

    if local_conf.apisix.ssl and local_conf.apisix.ssl.ssl_trusted_certificate then
        etcd_conf.trusted_ca = local_conf.apisix.ssl.ssl_trusted_certificate
    end

    if not health_check.conf then
        health_check.init({
            max_fails = 1,
            retry = true,
        })
    end

    return _new(etcd_conf)
end
_M.new = new


local function switch_proxy()
    if ngx_get_phase() == "init" or ngx_get_phase() == "init_worker" then
        return new_without_proxy()
    end

    local etcd_cli, prefix, err = new()
    if not etcd_cli or err then
        return etcd_cli, prefix, err
    end

    if not etcd_cli.unix_socket_proxy then
        return etcd_cli, prefix, err
    end
    local sock_path = etcd_cli.unix_socket_proxy:sub(#"unix:" + 1)
    local ok = pl_path.exists(sock_path)
    if not ok then
        return new_without_proxy()
    end

    return etcd_cli, prefix, err
end
_M.get_etcd_syncer = switch_proxy

-- convert ETCD v3 entry to v2 one
local function kvs_to_node(kvs)
    local node = {}
    node.key = kvs.key
    node.value = kvs.value
    node.createdIndex = tonumber(kvs.create_revision)
    node.modifiedIndex = tonumber(kvs.mod_revision)
    return node
end
_M.kvs_to_node = kvs_to_node

local function kvs_to_nodes(res, exclude_dir)
    res.body.node.dir = true
    res.body.node.nodes = setmetatable({}, array_mt)
    if exclude_dir then
        for i=2, #res.body.kvs do
            res.body.node.nodes[i-1] = kvs_to_node(res.body.kvs[i])
        end
    else
        for i=1, #res.body.kvs do
            res.body.node.nodes[i] = kvs_to_node(res.body.kvs[i])
        end
    end
    return res
end


local function not_found(res)
    res.body.message = "Key not found"
    res.reason = "Not found"
    res.status = 404
    return res
end


-- When `is_dir` is true, returns the value of both the dir key and its descendants.
-- Otherwise, return the value of key only.
function _M.get_format(res, real_key, is_dir, formatter)
    if res.body.error == "etcdserver: user name is empty" then
        return nil, "insufficient credentials code: 401"
    end

    if res.body.error == "etcdserver: permission denied" then
        return nil, "etcd forbidden code: 403"
    end

    if res.body.error then
        -- other errors, like "grpc: received message larger than max"
        return nil, res.body.error
    end

    res.headers["X-Etcd-Index"] = res.body.header.revision

    if not res.body.kvs then
        return not_found(res)
    end

    v3_adapter.to_v3(res.body, "get")

    if formatter then
        return formatter(res)
    end

    if not is_dir then
        local key = res.body.kvs[1].key
        if key ~= real_key then
            return not_found(res)
        end

        res.body.node = kvs_to_node(res.body.kvs[1])

    else
        -- In etcd v2, the direct key asked for is `node`, others which under this dir are `nodes`
        -- While in v3, this structure is flatten and all keys related the key asked for are `kvs`
        res.body.node = kvs_to_node(res.body.kvs[1])
        -- we have a init_dir (for etcd v2) value that can't be deserialized with json,
        -- but we don't put init_dir for new resource type like consumer credential
        if not res.body.kvs[1].value then
            -- remove last "/" when necessary
            if string.byte(res.body.node.key, -1) == 47 then
                res.body.node.key = string.sub(res.body.node.key, 1, #res.body.node.key-1)
            end
            res = kvs_to_nodes(res, true)
        else
            -- get dir key by remove last part of node key,
            -- for example: /apisix/consumers/jack -> /apisix/consumers
            local last_slash_index = string.find(res.body.node.key, "/[^/]*$")
            if last_slash_index then
                res.body.node.key = string.sub(res.body.node.key, 1, last_slash_index-1)
            end
            res = kvs_to_nodes(res, false)
        end
    end

    res.body.kvs = nil
    v3_adapter.to_v3_list(res.body)
    return res
end


function _M.watch_format(v3res)
    local v2res = {}
    v2res.headers = {
        ["X-Etcd-Index"] = v3res.result.header.revision
    }
    v2res.body = {
        node = {}
    }

    local compact_revision = v3res.result.compact_revision
    if compact_revision and tonumber(compact_revision) > 0 then
        -- When the revisions are compacted, there might be compacted changes
        -- which are unsynced. So we need to do a fully sync.
        -- TODO: cover this branch in CI
        return nil, "compacted"
    end

    for i, event in ipairs(v3res.result.events) do
        v2res.body.node[i] = kvs_to_node(event.kv)
        if event.type == "DELETE" then
            v2res.body.action = "delete"
        end
    end

    return v2res
end


local get_etcd_cli
do
    local prefix
    local etcd_cli_init_phase
    local etcd_cli
    local tmp_etcd_cli

    function get_etcd_cli()
        local err
        if ngx_get_phase() == "init" or ngx_get_phase() == "init_worker" then
            if etcd_cli_init_phase == nil then
                tmp_etcd_cli, prefix, err = new_without_proxy()
                if not tmp_etcd_cli then
                    return nil, nil, err
                end

                return tmp_etcd_cli, prefix
            end

            return etcd_cli_init_phase, prefix
        end

        if etcd_cli_init_phase ~= nil then
            -- we can't share the etcd instance created in init* phase
            -- they have different configuration
            etcd_cli_init_phase:close()
            etcd_cli_init_phase = nil
        end

        if etcd_cli == nil then
            tmp_etcd_cli, prefix, err = switch_proxy()
            if not tmp_etcd_cli then
                return nil, nil, err
            end

            etcd_cli = tmp_etcd_cli

            return tmp_etcd_cli, prefix
        end

        return etcd_cli, prefix
    end
end
-- export it so we can mock the etcd cli in test
_M.get_etcd_cli = get_etcd_cli


function _M.get(key, is_dir)
    local etcd_cli, prefix, err = get_etcd_cli()
    if not etcd_cli then
        return nil, err
    end

    key = prefix .. key

    -- in etcd v2, get could implicitly turn into readdir
    -- while in v3, we need to do it explicitly
    local res, err = etcd_cli:readdir(key)
    if not res then
        return nil, err
    end
    return _M.get_format(res, key, is_dir)
end


local function set(key, value, ttl)
    local disable, err = disable_write_if_data_plane()
    if disable then
        return nil, err
    end


    local etcd_cli, prefix, err = get_etcd_cli()
    if not etcd_cli then
        return nil, err
    end

    -- lease substitute ttl in v3
    local res, err
    if ttl then
        local data, grant_err = etcd_cli:grant(tonumber(ttl))
        if not data then
            return nil, grant_err
        end

        res, err = etcd_cli:set(prefix .. key, value, {prev_kv = true, lease = data.body.ID})
        if not res then
            return nil, err
        end

        res.body.lease_id = data.body.ID
    else
        res, err = etcd_cli:set(prefix .. key, value, {prev_kv = true})
    end
    if not res then
        return nil, err
    end

    if res.body.error then
        return nil, res.body.error
    end

    res.headers["X-Etcd-Index"] = res.body.header.revision

    -- etcd v3 set would not return kv info
    v3_adapter.to_v3(res.body, "set")
    res.body.node = {}
    res.body.node.key = prefix .. key
    res.body.node.value = value
    res.status = 201
    if res.body.prev_kv then
        res.status = 200
        res.body.prev_kv = nil
    end

    return res, nil
end
_M.set = set


function _M.atomic_set(key, value, ttl, mod_revision)
    local disable, err = disable_write_if_data_plane()
    if disable then
        return nil, err
    end

    local etcd_cli, prefix, err = get_etcd_cli()
    if not etcd_cli then
        return nil, err
    end

    local lease_id
    if ttl then
        local data, grant_err = etcd_cli:grant(tonumber(ttl))
        if not data then
            return nil, grant_err
        end

        lease_id = data.body.ID
    end

    key = prefix .. key

    local compare = {
        {
            key = key,
            target = "MOD",
            result = "EQUAL",
            mod_revision = mod_revision,
        }
    }

    local success = {
        {
            requestPut = {
                key = key,
                value = value,
                lease = lease_id,
            }
        }
    }

    local res, err = etcd_cli:txn(compare, success)
    if not res then
        return nil, err
    end

    if not res.body.succeeded then
        return nil, "value changed before overwritten"
    end

    res.headers["X-Etcd-Index"] = res.body.header.revision
    -- etcd v3 set would not return kv info
    v3_adapter.to_v3(res.body, "compareAndSwap")
    res.body.node = {
        key = key,
        value = value,
    }

    return res, nil
end



function _M.push(key, value, ttl)
    local disable, err = disable_write_if_data_plane()
    if disable then
        return nil, err
    end

    local etcd_cli, _, err = get_etcd_cli()
    if not etcd_cli then
        return nil, err
    end

    -- Create a new revision and use it as the id.
    -- It will be better if we use snowflake algorithm like manager-api,
    -- but we haven't found a good library. It costs too much to write
    -- our own one as the admin-api will be replaced by manager-api finally.
    local res, err = set("/gen_id", 1)
    if not res then
        return nil, err
    end

    -- manually add suffix
    local index = res.body.header.revision
    index = string.format("%020d", index)

    -- set the basic id attribute
    value.id = index

    res, err = set(key .. "/" .. index, value, ttl)
    if not res then
        return nil, err
    end

    v3_adapter.to_v3(res.body, "create")
    return res, nil
end


function _M.delete(key)
    local disable, err = disable_write_if_data_plane()
    if disable then
        return nil, err
    end

    local etcd_cli, prefix, err = get_etcd_cli()
    if not etcd_cli then
        return nil, err
    end

    local res, err = etcd_cli:delete(prefix .. key)

    if not res then
        return nil, err
    end

    res.headers["X-Etcd-Index"] = res.body.header.revision

    if not res.body.deleted then
        return not_found(res), nil
    end

    -- etcd v3 set would not return kv info
    v3_adapter.to_v3(res.body, "delete")
    res.body.node = {}
    res.body.key = prefix .. key

    return res, nil
end

function _M.rmdir(key, opts)
    local disable, err = disable_write_if_data_plane()
    if disable then
        return nil, err
    end

    local etcd_cli, prefix, err = get_etcd_cli()
    if not etcd_cli then
        return nil, err
    end

    local res, err = etcd_cli:rmdir(prefix .. key, opts)
    if not res then
        return nil, err
    end

    res.headers["X-Etcd-Index"] = res.body.header.revision

    if not res.body.deleted then
        return not_found(res), nil
    end

    v3_adapter.to_v3(res.body, "delete")
    res.body.node = {}
    res.body.key = prefix .. key

    return res, nil
end

---
-- Get etcd cluster and server version.
--
-- @function core.etcd.server_version
-- @treturn table The response of query etcd server version.
-- @usage
-- local res, err = core.etcd.server_version()
-- -- the res.body is as follows:
-- -- {
-- --   etcdcluster = "3.5.0",
-- --   etcdserver = "3.5.0"
-- -- }
function _M.server_version()
    local etcd_cli, _, err = get_etcd_cli()
    if not etcd_cli then
        return nil, err
    end

    return etcd_cli:version()
end


function _M.keepalive(id)
    local disable, err = disable_write_if_data_plane()
    if disable then
        return nil, err
    end

    local etcd_cli, _, err = get_etcd_cli()
    if not etcd_cli then
        return nil, err
    end

    local res, err = etcd_cli:keepalive(id)
    if not res then
        return nil, err
    end

    return res, nil
end


return _M
