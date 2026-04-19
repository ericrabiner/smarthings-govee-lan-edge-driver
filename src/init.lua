--[[
  Govee LAN Edge Driver for SmartThings

  Controls Govee lights over LAN via UDP.
  - Discovery: multicast scan on 239.255.255.250:4001, listen on port 4002
  - Control:   unicast UDP to device_ip:4003
]]

local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local socket = require "cosock.socket"
local json = require "st.json"
local log = require "log"

-- ── Constants ───────────────────────────────────────────────

local MULTICAST_GROUP = "239.255.255.250"
local SCAN_PORT = 4001
local LISTEN_PORT = 4002
local CONTROL_PORT = 4003
local SCAN_TIMEOUT = 4
local DEFAULT_IP = "192.168.1.100" -- change to your Govee device's IP

-- Map device_network_id -> IP, populated during discovery
local discovered_ips = {}

-- ── UDP helpers ─────────────────────────────────────────────

--- Send a JSON command to a Govee device.
---@param ip string  Device IP address
---@param cmd table  Command table (will be JSON-encoded)
local function send_command(ip, cmd)
  local payload = json.encode(cmd)
  local udp = socket.udp()
  udp:settimeout(0)
  local ok, err = udp:sendto(payload, ip, CONTROL_PORT)
  udp:close()
  if not ok then
    log.warn("send_command failed: " .. tostring(err))
  end
end

--- Get the stored IP for a device, falling back to DEFAULT_IP.
---@param device table  SmartThings device object
---@return string
local function get_ip(device)
  return device:get_field("ip_address") or device.preferences.deviceIp or DEFAULT_IP
end

-- ── Govee commands ──────────────────────────────────────────

local function govee_turn(ip, on)
  send_command(ip, {
    msg = { cmd = "turn", data = { value = on and 1 or 0 } }
  })
end

local function govee_brightness(ip, level)
  level = math.max(1, math.min(100, level))
  send_command(ip, {
    msg = { cmd = "brightness", data = { value = level } }
  })
end

local function govee_color(ip, r, g, b)
  send_command(ip, {
    msg = {
      cmd = "colorwc",
      data = {
        color = { r = r % 256, g = g % 256, b = b % 256 },
        colorTemInKelvin = 0,
      },
    },
  })
end

local function govee_color_temp(ip, kelvin)
  kelvin = math.max(2000, math.min(9000, kelvin))
  send_command(ip, {
    msg = {
      cmd = "colorwc",
      data = {
        color = { r = 0, g = 0, b = 0 },
        colorTemInKelvin = kelvin,
      },
    },
  })
end

-- ── HSV → RGB conversion ───────────────────────────────────

local function hsv_to_rgb(hue, sat)
  -- hue: 0-360, sat: 0-100
  local h = (hue or 0) / 360
  local s = (sat or 0) / 100
  local v = 1.0

  if s == 0 then
    local c = math.floor(v * 255)
    return c, c, c
  end

  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p = math.floor(v * (1 - s) * 255)
  local q = math.floor(v * (1 - f * s) * 255)
  local t = math.floor(v * (1 - (1 - f) * s) * 255)
  local vi = math.floor(v * 255)

  i = i % 6
  if i == 0 then return vi, t, p
  elseif i == 1 then return q, vi, p
  elseif i == 2 then return p, vi, t
  elseif i == 3 then return p, q, vi
  elseif i == 4 then return t, p, vi
  else return vi, p, q
  end
end

-- ── Capability command handlers ─────────────────────────────

local function handle_switch_on(driver, device, command)
  local ip = get_ip(device)
  log.info("switch on -> " .. ip)
  govee_turn(ip, true)
  device:emit_event(capabilities.switch.switch.on())
end

local function handle_switch_off(driver, device, command)
  local ip = get_ip(device)
  log.info("switch off -> " .. ip)
  govee_turn(ip, false)
  device:emit_event(capabilities.switch.switch.off())
end

local function handle_set_level(driver, device, command)
  local ip = get_ip(device)
  local level = command.args.level
  log.info(string.format("setLevel %d -> %s", level, ip))
  govee_brightness(ip, level)
  device:emit_event(capabilities.switchLevel.level(level))
  if level > 0 then
    device:emit_event(capabilities.switch.switch.on())
  end
end

local function handle_set_color(driver, device, command)
  local ip = get_ip(device)
  local hue = math.floor(command.args.color.hue + 0.5)
  local sat = math.floor(command.args.color.saturation + 0.5)
  local r, g, b = hsv_to_rgb(hue, sat)
  log.info(string.format("setColor hue=%d sat=%d -> (%d,%d,%d) -> %s", hue, sat, r, g, b, ip))
  govee_color(ip, r, g, b)
  device:emit_event(capabilities.colorControl.hue(hue))
  device:emit_event(capabilities.colorControl.saturation(sat))
  device:emit_event(capabilities.switch.switch.on())
end

local function handle_set_hue(driver, device, command)
  local ip = get_ip(device)
  local hue = math.floor(command.args.hue + 0.5)
  local sat = math.floor((device:get_latest_state("main", "colorControl", "saturation") or 100) + 0.5)
  local r, g, b = hsv_to_rgb(hue, sat)
  log.info(string.format("setHue %d -> (%d,%d,%d) -> %s", hue, r, g, b, ip))
  govee_color(ip, r, g, b)
  device:emit_event(capabilities.colorControl.hue(hue))
end

local function handle_set_saturation(driver, device, command)
  local ip = get_ip(device)
  local sat = math.floor(command.args.saturation + 0.5)
  local hue = math.floor((device:get_latest_state("main", "colorControl", "hue") or 0) + 0.5)
  local r, g, b = hsv_to_rgb(hue, sat)
  log.info(string.format("setSaturation %d -> (%d,%d,%d) -> %s", sat, r, g, b, ip))
  govee_color(ip, r, g, b)
  device:emit_event(capabilities.colorControl.saturation(sat))
end

local function handle_set_color_temp(driver, device, command)
  local ip = get_ip(device)
  local kelvin = command.args.temperature
  log.info(string.format("setColorTemperature %dK -> %s", kelvin, ip))
  govee_color_temp(ip, kelvin)
  device:emit_event(capabilities.colorTemperature.colorTemperature(kelvin))
  device:emit_event(capabilities.switch.switch.on())
end

-- ── Discovery ───────────────────────────────────────────────

local function try_add_device(driver, device_ip, sku, device_id)
  sku = sku or "H619C"
  device_id = device_id or device_ip

  log.info(string.format("Adding device: %s at %s (id=%s)", sku, device_ip, device_id))

  -- Store IP so device_init can pick it up
  discovered_ips[device_id] = device_ip

  local create_device_msg = {
    type = "LAN",
    device_network_id = device_id,
    label = "Govee " .. sku,
    profile = "govee-color-light",
    manufacturer = "Govee",
    model = sku,
    vendor_provided_label = "Govee " .. sku,
  }

  local ok, err = pcall(function()
    driver:try_create_device(create_device_msg)
  end)
  if ok then
    log.info("Device creation requested: " .. device_ip)
    return true
  else
    log.error("Device creation failed: " .. tostring(err))
    return false
  end
end

local function discovery_handler(driver, opts, cons)
  log.info("Starting Govee LAN discovery...")

  local found = false
  local scan_msg = json.encode({
    msg = { cmd = "scan", data = { account_topic = "reserve" } }
  })

  -- Try 1: multicast scan
  local send_sock = socket.udp()
  send_sock:settimeout(0)

  local recv_sock = socket.udp()
  recv_sock:setoption("reuseaddr", true)
  recv_sock:setsockname("0.0.0.0", LISTEN_PORT)
  local mcast_ok, mcast_err = pcall(function()
    recv_sock:setoption("ip-add-membership", { multiaddr = MULTICAST_GROUP, interface = "0.0.0.0" })
  end)
  if not mcast_ok then
    log.warn("Multicast join failed: " .. tostring(mcast_err))
  end
  recv_sock:settimeout(SCAN_TIMEOUT)

  send_sock:sendto(scan_msg, MULTICAST_GROUP, SCAN_PORT)
  log.info("Multicast scan sent to " .. MULTICAST_GROUP .. ":" .. SCAN_PORT)

  -- Also send unicast scan directly to known IP
  send_sock:sendto(scan_msg, DEFAULT_IP, SCAN_PORT)
  log.info("Unicast scan sent to " .. DEFAULT_IP .. ":" .. SCAN_PORT)

  -- Collect responses
  local deadline = socket.gettime() + SCAN_TIMEOUT
  while socket.gettime() < deadline do
    local data, ip, port = recv_sock:receivefrom()
    if data then
      log.info("Received response from " .. tostring(ip) .. ":" .. tostring(port))
      local ok, msg = pcall(json.decode, data)
      if ok and msg and msg.msg and msg.msg.cmd == "scan" then
        local info = msg.msg.data
        local device_ip = info.ip
        local sku = info.sku or "unknown"
        local device_id = info.device or device_ip

        log.info(string.format("Found: %s at %s (id=%s)", sku, device_ip, device_id))
        found = try_add_device(driver, device_ip, sku, device_id)
      end
    end
  end

  send_sock:close()
  recv_sock:close()

  -- Fallback: if no device found, add with known default IP
  if not found then
    log.info("No scan response received. Adding device with default IP: " .. DEFAULT_IP)
    try_add_device(driver, DEFAULT_IP, "H619C", "govee-h619c-" .. DEFAULT_IP)
  end

  log.info("Discovery complete")
end

-- ── Lifecycle ───────────────────────────────────────────────

local function device_added(driver, device)
  log.info("Device added: " .. device.label)
  device:emit_event(capabilities.switch.switch.on())
  device:emit_event(capabilities.switchLevel.level(100))
  device:emit_event(capabilities.colorTemperature.colorTemperature(4000))
  device:emit_event(capabilities.colorControl.hue(0))
  device:emit_event(capabilities.colorControl.saturation(0))
  device:online()
end

local function device_init(driver, device)
  log.info("Device init: " .. device.label)
  -- Check if discovery stored an IP for this device
  local dnid = device.device_network_id
  local ip = discovered_ips[dnid]
  if ip then
    device:set_field("ip_address", ip, { persist = true })
    discovered_ips[dnid] = nil
    log.info("Set discovered IP: " .. ip)
  elseif not device:get_field("ip_address") then
    device:set_field("ip_address", DEFAULT_IP, { persist = true })
    log.info("Using default IP: " .. DEFAULT_IP)
  end
  device:online()
end

local function device_removed(driver, device)
  log.info("Device removed: " .. device.label)
end

-- ── Driver definition ───────────────────────────────────────

local driver = Driver("Govee LAN Light", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_level,
    },
    [capabilities.colorControl.ID] = {
      [capabilities.colorControl.commands.setColor.NAME] = handle_set_color,
      [capabilities.colorControl.commands.setHue.NAME] = handle_set_hue,
      [capabilities.colorControl.commands.setSaturation.NAME] = handle_set_saturation,
    },
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = handle_set_color_temp,
    },
  },
})

log.info("Starting Govee LAN Edge Driver")
driver:run()
