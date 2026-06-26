# Quality Guard — Reports Menu Injection — ROLLBACK PLAN

## What was changed (the ONLY core change)
A single <script> tag was added to the Chatwoot dashboard layout, mounted read-only
via docker-compose (same pattern as existing QAYDAO patches). No frontend rebuild,
no compiled-bundle edits. One line added; diff confirmed.

Files involved:
- /root/chat-qaydao/patches/views/layouts/vueapp.html.erb   (patched layout, mounted RO)
- docker-compose.yml  -> chatwoot-web volumes: added the mount line
- Sidecar serves the logic at https://chat.qaydao.com/quality-guard/inject.js
  (file: /root/chat-qaydao/quality-guard/app/static_inject.js)

Backups:
- /root/chat-qaydao/quality-guard/cw-patch/vueapp.html.erb.orig-<timestamp>  (untouched original)
- /root/chat-qaydao/docker-compose.yml.bak-qg-<timestamp>

## ROLLBACK (fully reverts the native-menu integration; QG sidecar keeps working)
1. Remove the mount line from docker-compose.yml:
     - ./patches/views/layouts/vueapp.html.erb:/app/app/views/layouts/vueapp.html.erb:ro
   (or restore docker-compose.yml from the .bak-qg-* backup)
2. Recreate only the web container:
     cd /root/chat-qaydao && docker compose up -d chatwoot-web
3. Verify the tag is gone:
     curl -s https://chat.qaydao.com/app/ | grep quality-guard   # (expect nothing)
   Verify site healthy:
     curl -s -o /dev/null -w "%{http_code}\n" https://chat.qaydao.com/   # expect 200

After rollback, Chatwoot is byte-identical to stock layout behavior. The Quality Guard
report page remains reachable directly at https://chat.qaydao.com/quality-guard/ and via
the DashboardApp tab (#2), which were NOT removed.

## Safety notes
- The injector is defensive: all logic wrapped in try/catch; it never throws into Chatwoot.
- It only appends menu items on /reports pages; touches no reports data path.
- Native Chatwoot reports endpoints verified 200 and unaffected after the change.
