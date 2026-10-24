SERVER
12Sep2026 - master branch deployment

================================================================================
ADMIN SITES & CREDENTIALS
================================================================================

  Auth Admin Panel:
    URL:      https://airgap.local:8089/admin/login
    Username: admin
    Password: admin123

  Storage Admin Dashboard:
    URL:      https://airgap.local:9001/admin/login
    Username: admin
    Password: admin123

  Wiki:         https://airgap.local:8080
  WebClient (GCS):
    URL:      https://airgap.local:8001

================================================================================
USER ACCOUNTS (file mode - file_db.json)
================================================================================

  Admin Users (full permissions, IsAdmin=true):
    single@airgap.droneengage.com / test       (0xffffffff)
    admin                               / admin123    (0xffffffff)

  GCS Only (GCS login + all actions, no unit login):
    gcs                                 / gcs         (0x83ffffff)

  Unit Only (unit login + unit action, no GCS login):
    unit                                / unit        (0x40000010)

  GCS View Only (GCS login + view mode, no actions):
    view                                / view        (0xa0000000)

  All users are in Team 1 (airgap).

================================================================================
SERVICES (pm2)
================================================================================

  de_auth        - Authenticator  7.6.6   (master)  port 19408 API, 8089 admin, 19001 S2S
  de_comm        - Comm Server    5.6.1   (master)  port 9966 WS
  de_storage     - Storage Server  1.1.1   (master)  port 9000 WS, 9001 dashboard
  de_web_server  - WebClient      3.1.0   (master)  port 8001 HTTPS (server.js + OpenSky proxy)
  de_wiki        - Wiki           (master)  port 8080 HTTPS (sphinx build/html)

  pm2 commands:
    pm2 list              - show status
    pm2 restart all       - restart everything
    pm2 logs <name>        - tail logs
    pm2 flush              - clear all logs

================================================================================
DEPLOYMENT NOTES
================================================================================

  - All servers on master branch, synced from local dev machine.
  - droneengage_server_common vendored into _vendor/ (airgap has no GitHub SSH).
    node_modules/droneengage_server_common -> ../_vendor/droneengage_server_common (symlink).
    package.json patched: git+ssh URL -> file:_vendor/droneengage_server_common (airgap-only).
  - Config: master server.config (airgap-configured) + server.config.local overrides.
    Auth:    .local switches to file mode (file_db.json with 5 users).
    Comm:    .local enables storage server (127.0.0.1:9000).
    Storage: .local sets public_host=airgap.local, dashboard 0.0.0.0, admin123,
             ignoreLog=true (disk logging disabled).
  - WebClient: server.js (Express + OpenSky CORS proxy) replaces old npx serve.
    SSL via env WEB_SSL_CRT/WEB_SSL_KEY -> /home/pi/ssl_local/ssl_airgap/.
    build/config.local.json: airgap.local:19408 + mapbox + ICE + ADSB + module versions.
    public/config.local.json: OpenSky CLIENT_ID/CLIENT_SECRET for server-side proxy.
  - pm2 startup enabled (pm2-pi systemd service). pm2 save persists process list.
  - pm2-logrotate installed: max 1M per file, keep 3 compressed copies.
  - UDP buffers tuned: rmem_max/wmem_max = 4194304 (persisted in /etc/sysctl.conf).
  - All server disk logging disabled. apt cache + npm cache cleared.

================================================================================
STANDALONE / INTERNET
================================================================================

  Works on internet (mapbox, OpenSky ADSB, STUN/TURN, module update URLs).
  Works offline (LAN) - external URLs fail gracefully, local WS/SSL unaffected.
  All inter-server connections are 127.0.0.1 loopback (no external dependencies).
