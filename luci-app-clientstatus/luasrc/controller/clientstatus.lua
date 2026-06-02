module("luci.controller.clientstatus", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/clientstatus") then
		return
	end

	entry({"admin", "services", "clientstatus"},
	      call("action_main"),
	      _("Client Management"), 60)

	entry({"admin", "services", "clientstatus", "status"},
	      template("clientstatus"),
	      _("Status"), 1)

	entry({"admin", "services", "clientstatus", "settings"},
	      cbi("clientstatus/settings"),
	      _("Settings"), 2)

	entry({"admin", "services", "clientstatus", "data"},
	      call("action_data"), nil).leaf = true

	entry({"admin", "services", "clientstatus", "mtime"},
	      call("action_mtime"), nil)

	entry({"admin", "services", "clientstatus", "speed"},
	      call("action_speed"), nil)

	entry({"admin", "services", "clientstatus", "toggle_acl"},
	      call("action_toggle_acl"), nil).leaf = true

	entry({"admin", "services", "clientstatus", "save_hostname"},
	      call("action_save_hostname"), nil).leaf = true

	entry({"admin", "services", "clientstatus", "reset"},
	      call("action_reset"), nil)

	entry({"admin", "services", "clientstatus", "speedlimit"},
	      call("action_speedlimit"), nil).leaf = true

	entry({"admin", "services", "clientstatus", "get_speedlimit"},
	      call("action_get_speedlimit"), nil)

	entry({"admin", "services", "clientstatus", "traffic_stats"},
	      call("action_traffic_stats"), nil)

	entry({"admin", "services", "clientstatus", "reset_traffic"},
	      call("action_reset_traffic"), nil)
end

function action_main()
	luci.http.redirect(
		luci.dispatcher.build_url("admin/services/clientstatus/status"))
end

local function valid_mac(mac)
	return mac ~= nil and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local function sanitize_hostname(name)
	if not name then return nil end
	name = name:match("^%s*(.-)%s*$") or name
	if #name == 0 then return nil end
	if #name > 64 then name = name:sub(1, 64) end
	name = name:gsub("[\1-\31\127]", "")
	if #name == 0 then return nil end
	return name
end

local function get_blocked_set()
	local uci = require("luci.model.uci").cursor()
	local set = {}
	local raw = uci:get("clientstatus", "global", "blocked_mac")
	if type(raw) == "table" then
		for _, mac in ipairs(raw) do set[mac:upper()] = true end
	elseif raw then
		set[raw:upper()] = true
	end
	return set
end

local function get_hostname_map()
	local uci = require("luci.model.uci").cursor()
	local map = {}
	uci:foreach("clientstatus", "device", function(s)
		if s.mac and s.hostname and s.hostname ~= "" then
			map[s.mac:upper()] = s.hostname
		end
	end)
	return map
end

local function send_usr1()
	local pid_f = io.open("/tmp/clientstatus.pid", "r")
	if pid_f then
		local pid = pid_f:read("*n")
		pid_f:close()
		if pid and pid > 0 then pcall(nixio.kill, pid, 10) end
	end
end

function action_mtime()
	send_usr1()
	local stat = nixio.fs.stat("/tmp/clientstatus")
	local mtime = stat and stat.mtime or 0
	luci.http.header("Cache-Control", "no-store, no-cache, must-revalidate")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ mtime = mtime })
end

function action_speed()
	send_usr1()

	local CACHE = "/tmp/clientstatus.speed_cache"
	local now = os.time()
	local alpha = 0.3

	-- 1. Read online clients and AP interfaces from /tmp/clientstatus
	local clients = {}
	local has_wifi = false
	local ap_list = {}
	local f = io.open("/tmp/clientstatus", "r")
	if not f then
		luci.http.prepare_content("application/json")
		luci.http.write_json({ clients = {}, updated = os.date("%Y-%m-%d %H:%M:%S") })
		return
	end
	for line in f:lines() do
		if line:sub(1, 1) == "#" then
			-- enabled: iwinfo path; conntrack: skip iwinfo; disabled: no wifi at all
			if line:match("WiFi:%s*enabled") then
				has_wifi = true
			end
			if has_wifi then
				local ap_entry = line:match("^# AP:%s*(.+)")
				if ap_entry then
					local iface = ap_entry:match("^(.-)|")
					if iface and iface ~= "" then
						ap_list[#ap_list + 1] = iface
					end
				end
			end
		else
			local parts = {}
			for p in line:match("^%s*(.-)%s*$"):gmatch("%S+") do
				parts[#parts + 1] = p
			end
			if #parts >= 6 and parts[2] == "online" then
				local mac = parts[1]:upper()
				local ip = parts[4]
				local cnt = parts[6] or "Ethernet"
				if ip == "\226\128\148" or ip == "-" then ip = nil end
				clients[mac] = {
					ip = ip,
					wifi = (cnt ~= "Ethernet" and cnt ~= "\226\128\148" and cnt ~= "")
				}
			end
		end
	end
	f:close()

	-- 2. Collect per-MAC byte counters
	local mac_rx, mac_tx = {}, {}

	-- 2a. WiFi bytes via ubus call iwinfo assoclist (only when enabled)
	if has_wifi and #ap_list > 0 then
		local json = require("luci.jsonc")
		for _, iface in ipairs(ap_list) do
			local sf = io.popen(string.format(
				'ubus call iwinfo assoclist \'{"device":"%s"}\' 2>/dev/null', iface))
			if sf then
				local out = sf:read("*a")
				sf:close()
				if out and #out > 10 then
					local ok, data = pcall(json.parse, out)
					if ok and data and data.results then
						for _, sta in ipairs(data.results) do
							if sta.mac then
								local um = sta.mac:upper()
								if clients[um] then
									local tx_bytes = sta.tx and sta.tx.bytes or 0
									local rx_bytes = sta.rx and sta.rx.bytes or 0
									mac_rx[um] = (mac_rx[um] or 0) + tx_bytes
									mac_tx[um] = (mac_tx[um] or 0) + rx_bytes
								end
							end
						end
					end
				end
			end
		end
	end

	-- 2b. Conntrack bytes
	--     enabled mode: wired clients only
	--     conntrack/disabled mode: all clients
	local ip_to_mac = {}
	for mac, info in pairs(clients) do
		if info.ip then
			if has_wifi then
				-- enabled: only wired clients via conntrack
				if not info.wifi then
					ip_to_mac[info.ip] = mac
				end
			else
				-- conntrack or disabled: all clients via conntrack
				ip_to_mac[info.ip] = mac
			end
		end
	end

	if next(ip_to_mac) then
		local ct = io.open("/proc/net/nf_conntrack", "r")
		if ct then
			for line in ct:lines() do
				if not line:match("^ipv6") then
					local src_ip = line:match("src=(%d+%.%d+%.%d+%.%d+)")
					local mac = src_ip and ip_to_mac[src_ip]
					if mac then
						local first = true
						local b1, b2
						for bv in line:gmatch("bytes=(%d+)") do
							if first then
								b1 = tonumber(bv)
								first = false
							else
								b2 = tonumber(bv)
								break
							end
						end
						if b1 then mac_tx[mac] = (mac_tx[mac] or 0) + b1 end
						if b2 then mac_rx[mac] = (mac_rx[mac] or 0) + b2 end
					end
				end
			end
			ct:close()
		end
	end

	-- 3. Read previous cache
	local cache = {}
	local cf = io.open(CACHE, "r")
	if cf then
		for line in cf:lines() do
			local p = {}
			for v in line:gmatch("[^|]+") do
				p[#p + 1] = v
			end
			if #p >= 6 then
				cache[p[1]] = {
					rx  = tonumber(p[2]) or 0,
					tx  = tonumber(p[3]) or 0,
					srx = tonumber(p[4]) or 0,
					stx = tonumber(p[5]) or 0,
					ts  = tonumber(p[6]) or 0
				}
			end
		end
		cf:close()
	end

	-- 4. Compute speeds with EWMA smoothing
	local result = {}
	for mac in pairs(clients) do
		local cur_rx = mac_rx[mac] or 0
		local cur_tx = mac_tx[mac] or 0
		local c = cache[mac]
		local rx_spd, tx_spd = 0, 0

		if c and c.ts > 0 and now > c.ts and (now - c.ts) <= 10 then
			local dt = now - c.ts
			local irx = math.max(0, (cur_rx - c.rx) / dt)
			local itx = math.max(0, (cur_tx - c.tx) / dt)
			rx_spd = alpha * irx + (1 - alpha) * (c.srx or 0)
			tx_spd = alpha * itx + (1 - alpha) * (c.stx or 0)
		end

		result[mac] = {
			rx = math.floor(rx_spd + 0.5),
			tx = math.floor(tx_spd + 0.5)
		}

		cache[mac] = {
			rx = cur_rx,
			tx = cur_tx,
			srx = rx_spd,
			stx = tx_spd,
			ts = now
		}
	end

	-- 5. Write cache atomically
	local tmp = CACHE .. ".tmp"
	local wf = io.open(tmp, "w")
	if wf then
		for m, c in pairs(cache) do
			wf:write(string.format("%s|%d|%d|%.1f|%.1f|%d\n",
				m, c.rx, c.tx, c.srx, c.stx, c.ts))
		end
		wf:close()
		os.rename(tmp, CACHE)
	end

	-- 6. Return JSON
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		clients = result,
		updated = os.date("%Y-%m-%d %H:%M:%S")
	})
end

function action_data()
	local blocked_set = get_blocked_set()
	local hostname_map = get_hostname_map()
	local result = { clients = {}, updated = nil }
	local f = io.open("/tmp/clientstatus", "r")
	if not f then
		-- Fallback: read directly from ARP + DHCP when daemon is not running
		result = action_data_fallback(blocked_set, hostname_map)
		luci.http.prepare_content("application/json")
		luci.http.write_json(result)
		return
	end
	for line in f:lines() do
		if line:sub(1, 1) == "#" then
			local ts = line:match("Client Status .+%-%- (.+)") or
			           line:match("Client Status .+\226\128\148 (.+)")
			if ts then result.updated = ts end
		else
			local trimmed = line:match("^%s*(.-)%s*$") or line
			if trimmed ~= "" then
				-- Fixed-width format from C daemon:
				-- printf "%-17s  %-8s  %-10s  %-16s  %-20s  %-10s"
				-- MAC(17) + 2sp + STATUS(8) + 2sp + DURATION(10) + 2sp + IPv4(16) + 2sp + HOSTNAME(20) + 2sp + CNT(10)
				local mac = trimmed:sub(1, 17):match("^%s*(.-)%s*$")
				local status = trimmed:sub(20, 27):match("^%s*(.-)%s*$")
				local duration = trimmed:sub(30, 39):match("^%s*(.-)%s*$")
				local ipv4 = trimmed:sub(42, 57):match("^%s*(.-)%s*$")
				local hostname = trimmed:sub(60, 79):match("^%s*(.-)%s*$")
				local cnt = trimmed:sub(82):match("^%s*(.-)%s*$")
				
				if valid_mac(mac) and (status == "online" or status == "offline") then
					if ipv4 == "-" then ipv4 = "" end
					if hostname == "-" or hostname == "" then hostname = "\226\128\148" end
					local nct = "Ethernet"
					if cnt ~= "" and cnt ~= "Ethernet" then nct = cnt end
					local acl_status = blocked_set[mac:upper()] and "Blocked" or "Allowed"
					local custom_name = hostname_map[mac:upper()]
					local display_name = hostname
					local is_custom = false
					if custom_name then display_name = custom_name; is_custom = true end
					result.clients[#result.clients + 1] = {
						mac = mac,
						status = status,
						duration = duration,
						ipv4 = ipv4,
						hostname = display_name,
						orig_hostname = hostname,
						custom = is_custom,
						nct = nct,
						acl = acl_status
					}
				end
			end
		end
	end
	f:close()
	table.sort(result.clients, function(a, b)
		if a.status ~= b.status then return a.status == "online" end
		return a.mac < b.mac
	end)
	luci.http.prepare_content("application/json")
	luci.http.write_json(result)
end

-- Fallback: collect clients from ARP + DHCP when /tmp/clientstatus does not exist
function action_data_fallback(blocked_set, hostname_map)
	local result = { clients = {}, updated = os.date("%Y-%m-%d %H:%M:%S") }

	-- Read ARP table
	local arp_clients = {}
	local af = io.popen("cat /proc/net/arp 2>/dev/null")
	if af then
		af:read("*l") -- skip header
		for line in af:lines() do
			local parts = {}
			for p in line:gmatch("%S+") do parts[#parts + 1] = p end
			if #parts >= 4 and parts[4] ~= "00:00:00:00:00:00" then
				local mac = parts[4]:upper()
				if valid_mac(mac) then
					arp_clients[mac] = {
						ip = parts[1],
						device = parts[6] or ""
					}
				end
			end
		end
		af:close()
	end

	-- Read DHCP leases
	local dhcp_map = {}
	local df = io.open("/tmp/dhcp.leases", "r")
	if df then
		for line in df:lines() do
			local parts = {}
			for p in line:gmatch("%S+") do parts[#parts + 1] = p end
			if #parts >= 4 then
				local mac = parts[2]:upper()
				if valid_mac(mac) then
					local hostname = parts[4]
					-- Handle various "no hostname" cases
					if hostname == "*" or hostname == "" or hostname == "?" then
						hostname = ""
					end
					dhcp_map[mac] = {
						ip = parts[3],
						hostname = hostname
					}
				end
			end
		end
		df:close()
	end

	-- Read /etc/hosts for additional hostname resolution
	local hosts_map = {}
	local hf = io.open("/etc/hosts", "r")
	if hf then
		for line in hf:lines() do
			local ip, name = line:match("^%s*(%d+%.%d+%.%d+%.%d+)%s+(%S+)")
			if ip and name and name ~= "localhost" then
				hosts_map[ip] = name
			end
		end
		hf:close()
	end

	-- Merge: DHCP info + ARP info
	local merged = {}
	for mac, info in pairs(dhcp_map) do merged[mac] = info end
	for mac, info in pairs(arp_clients) do
		if not merged[mac] then
			-- Try to get hostname from /etc/hosts
			local hostname = hosts_map[info.ip] or ""
			merged[mac] = { ip = info.ip, hostname = hostname }
		end
	end

	-- Build client list
	for mac, info in pairs(merged) do
		local hostname = info.hostname or ""
		-- Use custom name if available
		local acl_status = blocked_set[mac] and "Blocked" or "Allowed"
		local custom_name = hostname_map[mac]
		local display_name = hostname
		local is_custom = false
		if custom_name then
			display_name = custom_name
			is_custom = true
		elseif hostname == "" then
			display_name = "—"
		end

		-- Determine connection type
		local nct = "Ethernet"
		local device = arp_clients[mac] and arp_clients[mac].device or ""
		if device ~= "" and device ~= "br-lan" then
			nct = device
		end

		result.clients[#result.clients + 1] = {
			mac = mac,
			status = "online",
			duration = "-",
			ipv4 = info.ip or "",
			hostname = display_name,
			orig_hostname = hostname ~= "" and hostname or "—",
			custom = is_custom,
			nct = nct,
			acl = acl_status
		}
	end

	table.sort(result.clients, function(a, b)
		return a.mac < b.mac
	end)
	return result
end

function action_toggle_acl()
	local http = require("luci.http")
	local uci  = require("luci.model.uci").cursor()
	local mac = http.formvalue("mac")
	if not mac or mac == "" then
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = "missing mac" })
		return
	end
	if not valid_mac(mac) then
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = "invalid mac format" })
		return
	end
	mac = mac:upper()
	local raw = uci:get("clientstatus", "global", "blocked_mac")
	local current = {}
	if type(raw) == "table" then current = raw elseif raw then current = {raw} end
	local found = false
	local new_list = {}
	for _, m in ipairs(current) do
		if m:upper() == mac then
			found = true
		else
			new_list[#new_list + 1] = m
		end
	end
	if not found then new_list[#new_list + 1] = mac end
	uci:delete("clientstatus", "global", "blocked_mac")
	if #new_list > 0 then uci:set("clientstatus", "global", "blocked_mac", new_list) end
	uci:save("clientstatus")
	uci:commit("clientstatus")
	http.prepare_content("application/json")
	http.write_json({ ok = true, mac = mac, blocked = not found })
end

function action_save_hostname()
	local http = require("luci.http")
	local uci  = require("luci.model.uci").cursor()
	local mac      = http.formvalue("mac")
	local hostname = http.formvalue("hostname")
	if not mac or mac == "" then
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = "missing mac" })
		return
	end
	if not valid_mac(mac) then
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = "invalid mac format" })
		return
	end
	mac = mac:upper()
	hostname = sanitize_hostname(hostname)
	local section_id = nil
	uci:foreach("clientstatus", "device", function(s)
		if s.mac and s.mac:upper() == mac then
			section_id = s[".name"]
			return false
		end
	end)
	if hostname then
		if section_id then
			uci:set("clientstatus", section_id, "hostname", hostname)
		else
			section_id = uci:add("clientstatus", "device")
			uci:set("clientstatus", section_id, "mac", mac)
			uci:set("clientstatus", section_id, "hostname", hostname)
		end
	else
		if section_id then uci:delete("clientstatus", section_id) end
	end
	uci:save("clientstatus")
	uci:commit("clientstatus")
	http.prepare_content("application/json")
	http.write_json({ ok = true, mac = mac, hostname = hostname or "" })
end

function action_reset()
	nixio.fs.unlink("/tmp/clientstatus")
	nixio.fs.unlink("/tmp/clientstatus.state")
	send_usr1()
	luci.http.prepare_content("application/json")
	luci.http.write_json({ ok = true })
end

-- Speed limit functions
local function get_speed_limit_map()
	local uci = require("luci.model.uci").cursor()
	local map = {}
	uci:foreach("clientstatus", "speedlimit", function(s)
		if s.mac then
			map[s.mac:upper()] = {
				download = tonumber(s.download) or 0,
				upload = tonumber(s.upload) or 0
			}
		end
	end)
	return map
end

function action_speedlimit()
	local http = require("luci.http")
	local uci = require("luci.model.uci").cursor()
	local sys = require("luci.sys")
	
	local mac = http.formvalue("mac")
	local download = http.formvalue("download") or "0"
	local upload = http.formvalue("upload") or "0"
	
	if not mac or mac == "" then
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = "missing mac" })
		return
	end
	
	if not valid_mac(mac) then
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = "invalid mac format" })
		return
	end
	
	mac = mac:upper()
	download = tonumber(download) or 0
	upload = tonumber(upload) or 0
	
	-- Find existing section
	local section_id = nil
	uci:foreach("clientstatus", "speedlimit", function(s)
		if s.mac and s.mac:upper() == mac then
			section_id = s[".name"]
			return false
		end
	end)
	
	if download > 0 or upload > 0 then
		if section_id then
			uci:set("clientstatus", section_id, "download", tostring(download))
			uci:set("clientstatus", section_id, "upload", tostring(upload))
		else
			section_id = uci:add("clientstatus", "speedlimit")
			uci:set("clientstatus", section_id, "mac", mac)
			uci:set("clientstatus", section_id, "download", tostring(download))
			uci:set("clientstatus", section_id, "upload", tostring(upload))
		end
		-- Apply tc rules
		apply_tc_limit(mac, download, upload)
	else
		if section_id then
			uci:delete("clientstatus", section_id)
		end
		-- Remove tc rules
		remove_tc_limit(mac)
	end
	
	uci:save("clientstatus")
	uci:commit("clientstatus")
	
	http.prepare_content("application/json")
	http.write_json({ 
		ok = true, 
		mac = mac, 
		download = download, 
		upload = upload 
	})
end

function action_get_speedlimit()
	local http = require("luci.http")
	local limits = get_speed_limit_map()
	http.prepare_content("application/json")
	http.write_json({ ok = true, limits = limits })
end

-- Traffic statistics functions
function action_traffic_stats()
	local http = require("luci.http")
	local fs = require("nixio.fs")
	local json = require("luci.jsonc")
	
	local stats_file = "/tmp/clientstatus_traffic.json"
	local stats = {}
	
	if fs.access(stats_file) then
		local content = fs.readfile(stats_file)
		if content then
			local ok, data = pcall(json.parse, content)
			if ok and data then
				stats = data
			end
		end
	end
	
	http.prepare_content("application/json")
	http.write_json({ ok = true, stats = stats })
end

function action_reset_traffic()
	local http = require("luci.http")
	local fs = require("nixio.fs")
	
	local stats_file = "/tmp/clientstatus_traffic.json"
	fs.unlink(stats_file)
	
	http.prepare_content("application/json")
	http.write_json({ ok = true })
end

-- Helper function to apply tc limit
function apply_tc_limit(mac, download, upload)
	local sys = require("luci.sys")
	local iface = "br-lan"
	
	-- Remove existing rules first
	remove_tc_limit(mac)
	
	-- Get IP for this MAC
	local ip = nil
	local f = io.open("/proc/net/arp", "r")
	if f then
		for line in f:lines() do
			local parts = {}
			for p in line:gmatch("%S+") do parts[#parts+1] = p end
			if #parts >= 4 and parts[4]:upper() == mac then
				ip = parts[1]
				break
			end
		end
		f:close()
	end
	
	if not ip then return end
	
	-- Setup tc qdisc if not exists
	os.execute(string.format("tc qdisc del dev %s root 2>/dev/null", iface))
	os.execute(string.format("tc qdisc add dev %s root handle 1: htb default 12", iface))
	
	-- Create class for download limit
	if download > 0 then
		local rate = download .. "kbit"
		os.execute(string.format(
			"tc class add dev %s parent 1: classid 1:2 htb rate %s ceil %s 2>/dev/null",
			iface, rate, rate))
		os.execute(string.format(
			"tc filter add dev %s protocol ip parent 1:0 prio 1 handle 3 fw classid 1:2 2>/dev/null",
			iface))
	end
	
	-- Create class for upload limit
	if upload > 0 then
		local rate = upload .. "kbit"
		os.execute(string.format(
			"tc class add dev %s parent 1: classid 1:3 htb rate %s ceil %s 2>/dev/null",
			iface, rate, rate))
		os.execute(string.format(
			"tc filter add dev %s protocol ip parent 1:0 prio 1 handle 2 fw classid 1:3 2>/dev/null",
			iface))
	end
	
	-- Mark packets with iptables
	if download > 0 then
		os.execute(string.format(
			"iptables -t mangle -A POSTROUTING -d %s -j MARK --set-mark 0x3 2>/dev/null",
			ip))
	end
	if upload > 0 then
		os.execute(string.format(
			"iptables -t mangle -A PREROUTING -s %s -j MARK --set-mark 0x2 2>/dev/null",
			ip))
	end
end

-- Helper function to remove tc limit
function remove_tc_limit(mac)
	local sys = require("luci.sys")
	local iface = "br-lan"
	
	-- Get IP for this MAC
	local ip = nil
	local f = io.open("/proc/net/arp", "r")
	if f then
		for line in f:lines() do
			local parts = {}
			for p in line:gmatch("%S+") do parts[#parts+1] = p end
			if #parts >= 4 and parts[4]:upper() == mac then
				ip = parts[1]
				break
			end
		end
		f:close()
	end
	
	-- Remove iptables rules
	if ip then
		os.execute(string.format(
			"iptables -t mangle -D POSTROUTING -d %s -j MARK --set-mark 0x3 2>/dev/null",
			ip))
		os.execute(string.format(
			"iptables -t mangle -D PREROUTING -s %s -j MARK --set-mark 0x2 2>/dev/null",
			ip))
	end
end
