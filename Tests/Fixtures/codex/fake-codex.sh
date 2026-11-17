# Synthetic Codex app-server for the self-test: answers JSON-RPC lines on stdin.
[ -n "$FAKE_CODEX_MARKER" ] && : > "$FAKE_CODEX_MARKER"
if [ "$*" != "-s read-only -a on-request app-server" ]; then echo "unexpected arguments: $*" >&2; exit 2; fi
mode="${FAKE_CODEX_MODE:-ok}"
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*)
      case "$line" in *'"name":"the-agentic-apple"'*) ;; *) echo "bad clientInfo" >&2; exit 3 ;; esac
      # A notification in the same write as the reply.
      printf '{"method":"fake/started","params":{}}\n{"id":%s,"result":{"userAgent":"fake-codex/0.0"}}\n' "$id"
      # Exit right after initialize: our next write hits a closed pipe.
      [ "$mode" = exit-after-init ] && exec 0<&- && exit 0 ;;
    *'"method":"initialized"'*)
      [ -n "$FAKE_CODEX_LOG" ] && echo initialized >> "$FAKE_CODEX_LOG" ;;
    *'"method":"account/rateLimits/read"'*)
      case "$mode" in
        stall) ;;
        die-stderr) echo "starting up" >&2; echo "Error: error sending request for url (https://example.invalid/)" >&2; exit 1 ;;
        die-silent) exit 0 ;;
        auth-error) printf '{"id":%s,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}\n' "$id" ;;
        other-error) printf '{"id":%s,"error":{"code":-32603,"message":"internal <failure>"}}\n' "$id" ;;
        *) printf 'not json at all\n{"id":%s,"result":%s}\n' "$id" "$(tr -d '\n' < "$FAKE_CODEX_RESPONSE")" ;;
      esac ;;
    *'"method":"account/read"'*)
      printf '{"id":%s,"result":{"account":{"type":"chatgpt","planType":"pro"}}}\n' "$id" ;;
  esac
done
