local m, s, o
local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()

local function get_interface_list()
    local ifaces = {}
    uci:foreach("network", "interface", function(s)
        if s[".name"] ~= "loopback" and s.proto then
            if s.device then
                ifaces[#ifaces + 1] = s.device
            end
        end
    end)
    table.sort(ifaces)
    return ifaces
end

m = Map("clientstatus", "客户端管理设置",
	"注意：修改网络设置后如果页面显示不正常，请重启服务。")

s = m:section(NamedSection, "global", "global", "基本设置")

o = s:option(Flag, "enabled", "启用",
	"启用或禁用客户端状态监控服务。")
o.default = "1"
o.rmempty = false

o = s:option(Value, "refresh_interval", "刷新间隔（秒）",
	"扫描所有客户端的频率。默认值：30秒。")
o.default = "30"
o.datatype = "and(uinteger,min(5))"
o.rmempty = false

o = s:option(Flag, "enable_speedlimit", "启用限速",
	"启用客户端限速功能。")
o.default = "1"
o.rmempty = false

o = s:option(Flag, "enable_traffic", "启用流量统计",
	"启用流量统计功能。")
o.default = "1"
o.rmempty = false

o = s:option(Value, "traffic_retention", "流量数据保留天数",
	"流量数据保留的天数。默认值：30天。")
o.default = "30"
o.datatype = "and(uinteger,min(1),max(365))"
o.rmempty = false

o = s:option(ListValue, "lan_iface", "LAN接口",
	"扫描客户端的网络接口。通常为 br-lan。")
o.widget = "select"

local ifaces = get_interface_list()
for _, iface in ipairs(ifaces) do
	o:value(iface)
end
o.default = "br-lan"

return m
