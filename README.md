# ACIN_HUB – Kiosk iPad con Alert Alimentazione, Luminosità Intelligente, MQTT e Upload Video

ACIN_HUB è un’app iPad stile kiosk (iOS 15.8+) che mostra contenuti web a schermo intero e integra:

- Overlay rosso full-screen quando il dispositivo viene scollegato dall’alimentazione, con allarme sonoro e pulsante OK.
- Gestione intelligente della luminosità con inattività e movimento (CoreMotion).
- Integrazione MQTT via WebSocket per inviare stato periodico e ricevere comandi remoti.
- Upload automatico in background di un video (5s, solo video, senza audio) dalla fotocamera frontale quando l’iPad viene scollegato.
- Pannello di “Impostazioni avanzate” con log MQTT, stato connessione e parametri configurabili.

## Requisiti
- Xcode 15/16/26 (testata con Xcode 26)
- iOS 15.8 target minimo
- Rete locale raggiungibile verso:
  - Web server (default): `http://10.107.188.153`
  - Broker MQTT via WebSocket (default): `ws://10.107.188.153:8888`
  - Endpoint upload video (default): `http://10.107.188.153:3006/upload`

## Funzionalità principali

### 1) WebView kiosk
- Carica l’URL base configurato con un eventuale fragment (es. `#kiosk/home`).
- Nasconde la status bar e mantiene l’esperienza full-screen.

### 2) Overlay rosso di alert alimentazione
- Mostrato quando l’iPad viene scollegato (battery state → `unplugged`).
- Testo: “CONNECT THE POWER ADAPTER” con icona `exclamationmark.triangle`.
- Il layer rosso non blocca l’interazione con la WebView sottostante, tranne il bottone OK.
- Allarme sonoro in loop con volume in crescendo (ramp) fino al massimo volume dell’app (non il volume di sistema).
- Pulsante “OK” chiude l’overlay e ferma l’allarme.
- Allo scollegamento:
  - Luminosità schermo impostata subito al massimo (100%).
  - Avvio registrazione video (solo video, senza audio) 5s e upload.
  - Invio immediato dello stato MQTT aggiornato con `batteryState: unplugged`.

### 3) Luminosità intelligente con inattività + movimento
- `IdleMotionBrightnessManager` rileva inattività (touch e movimento) e regola `UIScreen.main.brightness`.
- Parametri configurabili (persistiti via `UserDefaults`):
  - Dim brightness (default 10%)
  - Active brightness (default 70%)
  - Motion sensitivity (1…10, default 5) – usa `deviceMotion.userAcceleration` per ridurre falsi positivi.
  - Idle seconds (default 90s) – tempo di inattività prima di ridurre la luminosità.

### 4) MQTT via WebSocket
- Client MQTT minimale (3.1.1) su WebSocket, con CONNECT/PUBLISH/QoS 0, PING e SUBSCRIBE.
- Topic di pubblicazione stato (JSON):
  - `office/ipads/<deviceId>/status`
- Topic comandi:
  - `office/ipads/<deviceId>/cmd`
- Comandi supportati:
  - `get_status` → invia subito lo stato su `/status`.
  - `alert:<testo>` → mostra un banner di notifica.
  - `set_fragment:<valore>` → imposta/storicizza il fragment, ricarica la WebView.
  - `close_app` → forza la chiusura dell’app.

Esempio di payload stato:
```json
{
  "deviceName": "iPad Sala Riunioni",
  "batteryLevel": 85,
  "batteryState": "charging",
  "wifiIP": "192.168.1.45",
  "online": true,
  "topicBase": "office/ipads/device123",
  "fragment": "kiosk/home",
  "settings": {
    "dimBrightness": 20,
    "activeBrightness": 80,
    "motionThreshold": 5,
    "idleSeconds": 60
  },
  "timestamp": "2025-09-23T20:35:00Z"
}
