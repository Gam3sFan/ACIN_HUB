# ACIN_HUB Copilot Instructions

## Project Overview
ACIN_HUB is an iOS kiosk app for iPads (iOS 15.8+) that integrates several key features:
- Full-screen web content display
- Power disconnection alerts with sound and visual overlay
- Intelligent brightness management based on inactivity and motion
- MQTT over WebSocket integration for remote monitoring and control
- Background video capture and upload on power events

## Key Architecture Components

### Core Services
1. **WebView Kiosk** (`ContentView.swift`)
   - Main UI container handling full-screen web content
   - Manages power alert overlay and settings panel
   - Orchestrates interactions between other components

2. **Intelligent Brightness** (`IdleMotionBrightnessManager.swift`)
   - Uses CoreMotion for activity detection
   - Configurable brightness levels and timing
   - Key settings: `dimBrightness`, `activeBrightness`, `motionThreshold`, `idleSeconds`

3. **MQTT Communication** (`MQTTWebSocketClient.swift`)
   - Minimal MQTT 3.1.1 implementation over WebSocket
   - Topic pattern: `office/ipads/<deviceId>/{status,cmd}`
   - QoS 0 only, supports CONNECT/PUBLISH/SUBSCRIBE

### Data Flows
- Device status updates → MQTT status topic (periodic and on changes)
- Power disconnection → Triggers overlay, sound, video capture, MQTT update
- Motion/inactivity → Brightness adjustments via CoreMotion
- Remote commands → WebView fragment changes, alerts, app control

## Development Workflows

### Configuration
Default endpoints (configurable):
```
Web Server: http://10.107.188.153
MQTT WebSocket: ws://10.107.188.153:8888 
Video Upload: http://10.107.188.153:3006/upload
```

### Build Requirements
- Xcode 15/16/26 (tested with 26)
- iOS 15.8+ deployment target
- Network access to configured endpoints

## Project Conventions

### Device Identification
- Device IDs generated from device names: lowercase, alphanumeric only
- Example: "iPad Sala Riunioni" → "ipadsalariunioni"

### MQTT Patterns
- Status updates include device info, battery, network, settings
- Commands support: `get_status`, `alert:<text>`, `set_fragment:<value>`, `close_app`

### UI/UX Patterns
- Full-screen experience (hidden status bar)
- Red overlay for power alerts (non-blocking except OK button)
- Advanced settings panel for configuration and logs

## Integration Points
1. Web Content
   - Loads from configured base URL + optional fragment
   - Fragment persists across app restarts

2. MQTT Broker
   - WebSocket connection required
   - JSON payloads for status/commands

3. Video Upload
   - 5s front camera capture (video only)
   - HTTP POST to upload endpoint
   - Triggered by power disconnection

_Note: Update these instructions if endpoints, protocols, or integration patterns change._