# Govee LAN Edge Driver for SmartThings

A SmartThings Edge driver that controls Govee lights over LAN via UDP. Supports on/off, brightness, RGB color, and color temperature.

Tested with the Govee H619C light strip.

## How it works

- **Discovery**: sends a multicast scan on `239.255.255.250:4001` and listens for responses on port `4002`
- **Control**: sends unicast UDP commands to the device on port `4003`

## Prerequisites

- SmartThings hub (v2 or v3)
- Govee light with LAN API enabled (enable in the Govee Home app under device settings)
- [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli) installed
- Hub and Govee device on the same LAN

## Setup

### 1. Install the SmartThings CLI

```bash
npm i -g @smartthings/cli
```

### 2. Log in

```bash
smartthings login
```

### 3. Set your device IP

Edit `src/init.lua` and set `DEFAULT_IP` to your Govee device's local IP address. This is used as a fallback if multicast discovery doesn't find the device.

```lua
local DEFAULT_IP = "192.168.1.100" -- change to your Govee device's IP
```

### 4. Create a driver channel

```bash
smartthings edge:channels:create
```

Give it a name (e.g. "Govee LAN") and follow the prompts.

### 5. Package and upload the driver

```bash
smartthings edge:drivers:package .
```

### 6. Assign the driver to your channel

```bash
smartthings edge:channels:assign
```

Select the driver and your channel.

### 7. Enroll your hub in the channel

```bash
smartthings edge:channels:enroll
```

Select your hub and the channel.

### 8. Install the driver on your hub

```bash
smartthings edge:drivers:install
```

### 9. Add the device

In the SmartThings app: **Add Device → Scan for nearby devices**

### Debugging

View live driver logs:

```bash
smartthings edge:drivers:logcat <driver-id>
```

## Capabilities

| Capability | Controls |
|---|---|
| switch | On / Off |
| switchLevel | Brightness (1–100) |
| colorControl | RGB color (via HSV) |
| colorTemperature | White temperature (2000–9000K) |
